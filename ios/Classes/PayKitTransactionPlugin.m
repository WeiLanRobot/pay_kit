#import "PayKitTransactionPlugin.h"
#import <StoreKit/StoreKit.h>

@interface PayKitTransactionPlugin () <SKPaymentTransactionObserver, SKProductsRequestDelegate>
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, copy) NSString *writer;
@property(nonatomic, strong) NSMapTable<SKPaymentTransaction *, NSString *> *handles;
@property(nonatomic, strong) NSMapTable<NSString *, SKPaymentTransaction *> *objects;
@property(nonatomic, strong) NSHashTable<SKPaymentTransaction *> *finishSubmitted;
@property(nonatomic, strong) NSCache<NSString *, NSString *> *outcomes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FlutterResult> *finishReplies;
@property(nonatomic, strong) NSMutableDictionary<NSString *, SKProduct *> *products;
@property(nonatomic, strong) NSMapTable<SKRequest *, FlutterResult> *requests;
@end

@implementation PayKitTransactionPlugin

// All channel operations and SK1 callbacks are serialized on the main thread.
// Registration in an additional Flutter engine does not acquire the queue.
static __weak PayKitTransactionPlugin *activeOwner;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  PayKitTransactionPlugin *plugin = [[self alloc] init];
  plugin.channel = [FlutterMethodChannel methodChannelWithName:@"pay_kit/storekit1"
                                               binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:plugin.channel];
  [registrar publish:plugin]; // Ensures detachFromEngineForRegistrar: is called.
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // StoreKit objects may compare equal by fields. Use pointer identity in
    // both directions and let StoreKit own the actual transaction lifetime.
    _handles = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                                                  NSPointerFunctionsObjectPointerPersonality
                                     valueOptions:NSPointerFunctionsStrongMemory];
    _objects = [NSMapTable strongToWeakObjectsMapTable];
    _finishSubmitted = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory |
                                                        NSPointerFunctionsObjectPointerPersonality];
    _outcomes = [[NSCache alloc] init];
    _outcomes.countLimit = 1024; // Eviction safely degrades a late retry to not_found.
    _finishReplies = [NSMutableDictionary dictionary];
    _products = [NSMutableDictionary dictionary];
    _requests = [NSMapTable strongToStrongObjectsMapTable];
  }
  return self;
}

- (SKPaymentQueue *)queue { return [SKPaymentQueue defaultQueue]; }

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self stopObserving];
  self.channel = nil;
}

- (void)stopObserving {
  if (activeOwner == self) {
    [[self queue] removeTransactionObserver:self];
    activeOwner = nil;
  }
  NSArray<FlutterResult> *pendingReplies =
      [self.requests.objectEnumerator.allObjects arrayByAddingObjectsFromArray:self.finishReplies.allValues];
  for (SKRequest *request in self.requests.keyEnumerator) {
    request.delegate = nil;
    [request cancel];
  }
  [self.requests removeAllObjects];
  self.writer = nil;
  [self.finishReplies removeAllObjects];
  [self.handles removeAllObjects];
  [self.objects removeAllObjects];
  [self.products removeAllObjects];

  // Detach all pending work before a reply can re-enter or a queued delegate runs.
  FlutterError *error = [FlutterError errorWithCode:@"observer_stopped" message:nil details:nil];
  for (FlutterResult reply in pendingReplies) {
    reply(error);
  }
}

static FlutterError *PKError(NSString *code) {
  return [FlutterError errorWithCode:code message:nil details:nil];
}

// SKProduct cannot distinguish all App Store product types on StoreKit 1.
static NSString *PKCatalogError(NSString *product) {
  id catalog = NSBundle.mainBundle.infoDictionary[@"PayKitConsumableProductIdentifiers"];
  if (!catalog) return nil;
  if (![catalog isKindOfClass:NSArray.class]) return @"invalid_consumable_catalog";
  for (id identifier in catalog) {
    if (![identifier isKindOfClass:NSString.class] || ![identifier length]) return @"invalid_consumable_catalog";
  }
  return [catalog containsObject:product] ? nil : @"unsupported_product_type";
}

static NSString *PKStatus(SKPaymentTransaction *transaction) {
  switch (transaction.transactionState) {
    case SKPaymentTransactionStatePurchased:
    case SKPaymentTransactionStateRestored:
      return @"paid";
    case SKPaymentTransactionStateFailed: {
      NSError *error = transaction.error;
      if (![error.domain isEqualToString:SKErrorDomain]) return @"failed";
      if (error.code == SKErrorPaymentCancelled) return @"canceled";
      if (@available(iOS 12.2, *)) {
        if (error.code == SKErrorOverlayCancelled) return @"canceled";
      }
      return @"failed";
    }
    default:
      return @"pending"; // Purchasing, deferred and future states.
  }
}

static NSString *PKReceipt(void) {
  NSURL *url = [NSBundle mainBundle].appStoreReceiptURL;
  return url ? [[NSData dataWithContentsOfURL:url] base64EncodedStringWithOptions:0] : nil;
}

- (NSDictionary *)item:(SKPaymentTransaction *)transaction handle:(NSString *)handle {
  BOOL restored = transaction.transactionState == SKPaymentTransactionStateRestored;
  SKPaymentTransaction *original = restored ? transaction.originalTransaction : nil;
  SKPaymentTransaction *purchase = restored ? original : transaction;
  return @{
    @"handle": handle, @"status": PKStatus(transaction),
    @"productId": transaction.payment.productIdentifier,
    @"allowsUnownedFinish": @(PKCatalogError(transaction.payment.productIdentifier) == nil),
    @"queueId": transaction.transactionIdentifier ?: NSNull.null,
    @"originalTransactionId": original.transactionIdentifier ?: NSNull.null,
    @"transactionId": purchase.transactionIdentifier ?: NSNull.null,
    @"token": purchase.payment.applicationUsername ?: NSNull.null
  };
}

- (NSDictionary *)batch:(NSArray<SKPaymentTransaction *> *)transactions {
  NSMutableArray *items = [NSMutableArray arrayWithCapacity:transactions.count];
  BOOL includeReceipt = NO;
  for (SKPaymentTransaction *transaction in transactions) {
    NSString *handle = [self.handles objectForKey:transaction];
    if (!handle) {
      handle = [NSUUID UUID].UUIDString;
      [self.handles setObject:handle forKey:transaction];
      [self.objects setObject:transaction forKey:handle];
    }
    NSDictionary *item = [self item:transaction handle:handle];
    includeReceipt |= [item[@"status"] isEqualToString:@"paid"];
    [items addObject:item];
  }
  return @{@"writer": self.writer ?: @"", @"transactions": items, @"receipt": includeReceipt ? (PKReceipt() ?: @"") : @""};
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
  if (activeOwner == self) [self.channel invokeMethod:@"updated" arguments:[self batch:transactions]];
}

- (void)paymentQueue:(SKPaymentQueue *)queue removedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
  if (activeOwner != self) return;
  NSMutableArray *items = [NSMutableArray array];
  NSMutableArray<FlutterResult> *replies = [NSMutableArray array];
  for (SKPaymentTransaction *transaction in transactions) {
    NSString *handle = [self.handles objectForKey:transaction];
    if (handle) {
      [items addObject:[self item:transaction handle:handle]];
      FlutterResult pending = self.finishReplies[handle];
      if (pending) [replies addObject:pending];
      [self.finishReplies removeObjectForKey:handle];
      [self.finishSubmitted removeObject:transaction];
      [self.outcomes setObject:@"removed" forKey:handle];
      [self.objects removeObjectForKey:handle];
      [self.handles removeObjectForKey:transaction];
    }
  }
  if (items.count) {
    [self.channel invokeMethod:@"removed" arguments:@{@"writer": self.writer, @"transactions": items, @"receipt": @""}];
  }
  for (FlutterResult reply in replies) reply(@"finished");
}

// Only explicit attempts with a durable host order may add a payment.
- (BOOL)paymentQueue:(SKPaymentQueue *)queue shouldAddStorePayment:(SKPayment *)payment
          forProduct:(SKProduct *)product { return NO; }

- (void)finish:(NSDictionary *)arguments result:(FlutterResult)result {
  NSString *handle = arguments[@"handle"];
  if (![handle isKindOfClass:NSString.class]) { result(PKError(@"invalid_handle")); return; }
  NSString *outcome = [self.outcomes objectForKey:handle];
  if (outcome) { result(outcome); return; }
  SKPaymentQueue *queue = [self queue];
  SKPaymentTransaction *transaction = [self.objects objectForKey:handle];
  // The outcome cache can evict a tombstone under memory pressure before
  // StoreKit removes a still-live object. Never submit its finish twice.
  if (transaction && [self.finishSubmitted containsObject:transaction]) {
    result(@"submitted"); return;
  }
  if (!transaction || [queue.transactions indexOfObjectIdenticalTo:transaction] == NSNotFound) {
    result(PKError(@"not_found"));
    return;
  }
  NSString *status = PKStatus(transaction);
  if ([status isEqualToString:@"pending"] || ![status isEqualToString:arguments[@"status"]]) {
    result(PKError(@"state_changed"));
    return;
  }
  NSDictionary *proof = arguments[@"verifiedQueue"];
  if (proof) {
    if (![proof isKindOfClass:NSDictionary.class]) { result(PKError(@"invalid_proof")); return; }
    NSString *verified = proof[@"transactionId"];
    if (![verified isKindOfClass:NSString.class] || !verified.length ||
        transaction.transactionState != SKPaymentTransactionStatePurchased ||
        ![transaction.transactionIdentifier isEqualToString:verified] ||
        ![transaction.payment.productIdentifier isEqual:proof[@"productId"]] ||
        ![(transaction.payment.applicationUsername ?: NSNull.null) isEqual:proof[@"token"]] ||
        transaction.payment.quantity != 1 || PKCatalogError(transaction.payment.productIdentifier)) {
      result(PKError(@"state_changed")); return;
    }
    // A second object can enter the queue after Dart checks its last snapshot.
    for (SKPaymentTransaction *other in queue.transactions) {
      if (other != transaction &&
          ([other.transactionIdentifier isEqualToString:verified] ||
           (other.transactionState == SKPaymentTransactionStateRestored &&
            [other.originalTransaction.transactionIdentifier isEqualToString:verified]))) {
        result(PKError(@"ambiguous_transaction")); return;
      }
    }
  }
  self.finishReplies[handle] = [result copy];
  [self.finishSubmitted addObject:transaction];
  [queue finishTransaction:transaction];
  // SK1 has no synchronous acknowledgment. Only removedTransactions confirms
  // the outcome for this exact object. A timeout leaves the durable item open.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    FlutterResult pending = self.finishReplies[handle];
    if (pending) {
      [self.finishReplies removeObjectForKey:handle];
      pending(@"submitted");
    }
  });
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *writer = call.arguments[@"writer"];
  if (![writer isKindOfClass:NSString.class] || !writer.length) {
    result(PKError(@"invalid_writer")); return;
  }
  if ([call.method isEqualToString:@"bundleIdentifier"]) {
    result(NSBundle.mainBundle.bundleIdentifier); return;
  }
  SKPaymentQueue *queue = [self queue];
  if ([call.method isEqualToString:@"start"] && !activeOwner) {
    activeOwner = self;
    self.writer = writer;
    [queue addTransactionObserver:self];
  }
  if (activeOwner != self || ![self.writer isEqualToString:writer]) {
    if ([call.method isEqualToString:@"stop"]) { result(nil); return; }
    result(PKError(@"storekit_writer_conflict")); return;
  }
  if ([call.method isEqualToString:@"stop"]) {
    [self stopObserving]; result(nil); return;
  }
  NSString *product = call.arguments[@"productId"];
  if ([call.method isEqualToString:@"start"] || [call.method isEqualToString:@"snapshot"]) {
    result([self batch:queue.transactions]);
  } else if ([call.method isEqualToString:@"finish"]) {
    [self finish:call.arguments result:result];
  } else if ([call.method isEqualToString:@"prepare"]) {
    if (![SKPaymentQueue canMakePayments]) { result(PKError(@"cannot_pay")); return; }
    if (![product isKindOfClass:NSString.class] || !product.length) { result(PKError(@"unknown_product")); return; }
    NSString *catalogError = PKCatalogError(product);
    if (catalogError) { result(PKError(catalogError)); return; }
    SKProductsRequest *request = [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:product]];
    [self startRequest:request result:result];
  } else if ([call.method isEqualToString:@"purchase"]) {
    SKProduct *prepared = [product isKindOfClass:NSString.class] ? self.products[product] : nil;
    NSString *token = call.arguments[@"token"];
    if (!prepared || ![token isKindOfClass:NSString.class] || !token.length) {
      result(PKError(@"invalid_payment")); return;
    }
    for (SKPaymentTransaction *transaction in queue.transactions) {
      if ([transaction.payment.productIdentifier isEqualToString:product]) {
        result(PKError(@"duplicate_product")); return;
      }
    }
    SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:prepared];
    payment.applicationUsername = token;
    [queue addPayment:payment];
    result(nil);
  } else if ([call.method isEqualToString:@"refreshReceipt"]) {
    [self startRequest:[[SKReceiptRefreshRequest alloc] initWithReceiptProperties:nil] result:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)startRequest:(SKRequest *)request result:(FlutterResult)result {
  [self.requests setObject:[result copy] forKey:request];
  request.delegate = self;
  [request start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
  // SKRequest delegate callbacks may run on a private StoreKit queue.
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterResult result = [self.requests objectForKey:request];
    if (!result) return;
    [self.requests removeObjectForKey:request];
    SKProduct *product = response.products.firstObject;
    if (!product) { result(PKError(@"unknown_product")); return; }
    if (product.subscriptionPeriod || product.subscriptionGroupIdentifier.length) {
      [self.products removeObjectForKey:product.productIdentifier];
      result(PKError(@"unsupported_product_type"));
      return;
    }
    self.products[product.productIdentifier] = product;
    result(nil);
  });
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterResult result = [self.requests objectForKey:request];
    if (!result) return;
    [self.requests removeObjectForKey:request];
    result(PKError(@"store_request_failed"));
  });
}

- (void)requestDidFinish:(SKRequest *)request {
  if (![request isKindOfClass:SKReceiptRefreshRequest.class]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterResult result = [self.requests objectForKey:request];
    if (!result) return;
    [self.requests removeObjectForKey:request];
    result(PKReceipt());
  });
}

@end
