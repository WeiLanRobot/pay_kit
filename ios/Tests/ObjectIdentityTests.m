#import <XCTest/XCTest.h>
#import <StoreKit/StoreKit.h>
#import "PayKitTransactionPlugin.h"

@interface PayKitTransactionPlugin (TestAccess) <SKPaymentTransactionObserver, SKProductsRequestDelegate>
- (void)stopObserving;
- (void)startRequest:(SKRequest *)request result:(FlutterResult)result;
- (NSCache *)outcomes;
@end

@interface LocalQueue : NSObject
@property(nonatomic, copy) NSArray *transactions;
@property(nonatomic, strong) NSMutableArray *finished;
@property(nonatomic) NSUInteger registrations;
@end
@implementation LocalQueue
- (void)addTransactionObserver:(id)observer { self.registrations++; }
- (void)removeTransactionObserver:(id)observer { self.registrations--; }
- (void)finishTransaction:(id)transaction { [self.finished addObject:transaction]; }
@end

@interface TestPlugin : PayKitTransactionPlugin
@property(nonatomic, strong) LocalQueue *fixture;
@end
@implementation TestPlugin
- (SKPaymentQueue *)queue { return (SKPaymentQueue *)self.fixture; }
@end

// Hold requests until the test delivers a delegate callback.
@interface HeldProductsRequest : SKProductsRequest
@end
@implementation HeldProductsRequest
- (void)start {}
- (void)cancel {}
@end

@interface HeldReceiptRequest : SKReceiptRefreshRequest
@end
@implementation HeldReceiptRequest
- (void)start {}
- (void)cancel {}
@end

@interface LocalItem : NSObject
@property(nonatomic) SKPaymentTransactionState transactionState;
@property(nonatomic) NSInteger quantity;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, copy) NSString *transactionIdentifier;
@property(nonatomic, copy) NSString *productIdentifier;
@property(nonatomic, copy) NSString *applicationUsername;
@property(nonatomic, strong) LocalItem *originalTransaction;
@end
@implementation LocalItem
- (id)payment { return self; }
+ (instancetype)item:(SKPaymentTransactionState)state {
  LocalItem *item = [[LocalItem alloc] init];
  item.transactionState = state;
  item.productIdentifier = @"coins";
  item.quantity = 1;
  item.applicationUsername = @"same";
  return item;
}
@end

@interface RecordingChannel : NSObject
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSDictionary *arguments;
@end
@implementation RecordingChannel
- (void)invokeMethod:(NSString *)method arguments:(NSDictionary *)arguments {
  self.method = method;
  self.arguments = arguments;
}
@end

@interface ObjectIdentityTests : XCTestCase
@end
@implementation ObjectIdentityTests
- (id)call:(TestPlugin *)plugin method:(NSString *)method args:(NSDictionary *)args {
  NSMutableDictionary *arguments = [@{@"writer":@"A"} mutableCopy];
  [arguments addEntriesFromDictionary:args];
  __block id reply = nil;
  [plugin handleMethodCall:[FlutterMethodCall methodCallWithMethodName:method arguments:arguments]
                    result:^(id value) { reply = value; }];
  return reply;
}
- (void)testIdenticalFailuresPendingAndDisappearBeforeRemoval {
  LocalItem *a = [LocalItem item:SKPaymentTransactionStateFailed];
  LocalItem *b = [LocalItem item:SKPaymentTransactionStateFailed];
  b.productIdentifier = @"test.coins";
  LocalItem *pending = [LocalItem item:SKPaymentTransactionStateDeferred];
  LocalQueue *queue = [LocalQueue new];
  queue.finished = [NSMutableArray array];
  queue.transactions = @[a, b, pending];
  TestPlugin *plugin = [TestPlugin new];
  plugin.fixture = queue;
  NSArray *items = [self call:plugin method:@"start" args:@{}][@"transactions"];
  NSArray *replay = [self call:plugin method:@"start" args:@{}][@"transactions"];
  XCTAssertEqualObjects(items, replay);
  XCTAssertEqualObjects(items[0][@"allowsUnownedFinish"], @NO);
  XCTAssertEqualObjects(items[1][@"allowsUnownedFinish"], @YES);
  XCTAssertEqual(queue.registrations, 1u);
  TestPlugin *other = [TestPlugin new];
  other.fixture = queue;
  FlutterError *owner = [self call:other method:@"start" args:@{}];
  XCTAssertEqualObjects(owner.code, @"storekit_writer_conflict");
  FlutterError *isolate = [self call:plugin method:@"start" args:@{@"writer":@"B"}];
  XCTAssertEqualObjects(isolate.code, @"storekit_writer_conflict");
  XCTAssertNotEqualObjects(items[0][@"handle"], items[1][@"handle"]);
  queue.transactions = @[b, pending];
  FlutterError *missing = [self call:plugin method:@"finish" args:items[0]];
  XCTAssertEqualObjects(missing.code, @"not_found");
  FlutterError *waiting = [self call:plugin method:@"finish" args:items[2]];
  XCTAssertEqualObjects(waiting.code, @"state_changed");
  XCTAssertEqual(queue.finished.count, 0u);
  [plugin paymentQueue:(SKPaymentQueue *)queue removedTransactions:@[(id)a]];
  XCTAssertEqualObjects([self call:plugin method:@"finish" args:items[0]], @"removed");
  NSMutableDictionary *finishArgs = [items[1] mutableCopy];
  finishArgs[@"writer"] = @"A";
  __block id confirmation = nil;
  [plugin handleMethodCall:[FlutterMethodCall methodCallWithMethodName:@"finish" arguments:finishArgs]
                    result:^(id value) { confirmation = value; }];
  XCTAssertNil(confirmation);
  XCTAssertEqualObjects([self call:plugin method:@"finish" args:items[1]], @"submitted");
  queue.transactions = @[pending];
  [plugin paymentQueue:(SKPaymentQueue *)queue removedTransactions:@[(id)b]];
  XCTAssertEqualObjects(confirmation, @"finished");
  XCTAssertEqualObjects([self call:plugin method:@"finish" args:items[1]], @"removed");
  [[plugin outcomes] removeAllObjects];
  FlutterError *forgotten = [self call:plugin method:@"finish" args:items[1]];
  XCTAssertEqualObjects(forgotten.code, @"not_found");
  XCTAssertEqualObjects(queue.finished, (@[b]));
  [plugin stopObserving];
  XCTAssertEqual(queue.registrations, 0u);
  NSArray *afterDetach = [self call:other method:@"start" args:@{}][@"transactions"];
  XCTAssertNotEqualObjects(items[2][@"handle"], afterDetach[0][@"handle"]);
  [other stopObserving];
}

- (void)testProofRechecksNativeQueueImmediatelyBeforeDispatch {
  LocalItem *item = [LocalItem item:SKPaymentTransactionStatePurchased];
  item.transactionIdentifier = @"T";
  item.productIdentifier = @"test.coins";
  LocalQueue *queue = [LocalQueue new];
  queue.transactions = @[item];
  queue.finished = [NSMutableArray array];
  TestPlugin *plugin = [TestPlugin new];
  plugin.fixture = queue;
  RecordingChannel *channel = [RecordingChannel new];
  [plugin setValue:channel forKey:@"channel"];
  NSDictionary *snapshot = [self call:plugin method:@"start" args:@{}];
  NSMutableDictionary *args = [snapshot[@"transactions"][0] mutableCopy];
  args[@"verifiedQueue"] = @{@"transactionId": @"T", @"productId": @"test.coins", @"token": @"same"};

  // Another handle appeared before the channel call, without a Dart update.
  LocalItem *duplicate = [LocalItem item:SKPaymentTransactionStatePurchased];
  duplicate.transactionIdentifier = @"T";
  queue.transactions = @[item, duplicate];
  XCTAssertEqualObjects([(FlutterError *)[self call:plugin method:@"finish" args:args] code], @"ambiguous_transaction");
  LocalItem *restore = [LocalItem item:SKPaymentTransactionStateRestored];
  restore.transactionIdentifier = @"restore";
  restore.originalTransaction = duplicate;
  queue.transactions = @[item, restore];
  XCTAssertEqualObjects([(FlutterError *)[self call:plugin method:@"finish" args:args] code], @"ambiguous_transaction");

  NSArray *both = [self call:plugin method:@"snapshot" args:@{}][@"transactions"];
  queue.transactions = @[item];
  [plugin paymentQueue:(SKPaymentQueue *)queue removedTransactions:@[(id)restore]];
  XCTAssertEqualObjects(channel.method, @"removed");
  XCTAssertEqualObjects(channel.arguments[@"writer"], @"A");
  XCTAssertEqualObjects(channel.arguments[@"transactions"][0][@"handle"], both[1][@"handle"]);
  XCTAssertEqualObjects(channel.arguments[@"receipt"], @"");
  item.quantity = 2;
  XCTAssertEqualObjects([(FlutterError *)[self call:plugin method:@"finish" args:args] code], @"state_changed");
  item.quantity = 1;
  item.applicationUsername = @"another";
  XCTAssertEqualObjects([(FlutterError *)[self call:plugin method:@"finish" args:args] code], @"state_changed");
  item.applicationUsername = @"same";
  XCTAssertEqual(queue.finished.count, 0u);
  XCTAssertNil([self call:plugin method:@"finish" args:args]);
  XCTAssertEqualObjects(queue.finished, (@[item]));
  [plugin paymentQueue:(SKPaymentQueue *)queue removedTransactions:@[(id)item]];
  XCTAssertEqualObjects(channel.arguments[@"transactions"][0][@"handle"], args[@"handle"]);
  [plugin stopObserving];
}

- (void)testStopCompletesPendingStoreRequestsOnce {
  TestPlugin *plugin = [TestPlugin new];
  plugin.fixture = [LocalQueue new];
  [self call:plugin method:@"start" args:@{}];

  HeldProductsRequest *products = [[HeldProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:@"test.coins"]];
  HeldReceiptRequest *receipt = [[HeldReceiptRequest alloc] initWithReceiptProperties:nil];
  NSMutableArray *productReplies = [NSMutableArray array];
  NSMutableArray *receiptReplies = [NSMutableArray array];
  [plugin startRequest:products result:^(id value) {
    [productReplies addObject:value ?: NSNull.null];
    // A reply can synchronously re-enter stop. The other requests still need
    // their own response, and this request must not receive a second one.
    if (productReplies.count == 1) [plugin stopObserving];
  }];
  [plugin startRequest:receipt result:^(id value) {
    [receiptReplies addObject:value ?: NSNull.null];
  }];

  // StoreKit's delegate may already have queued a response on the main thread.
  [plugin productsRequest:products didReceiveResponse:[SKProductsResponse new]];
  [plugin requestDidFinish:receipt];
  [self call:plugin method:@"stop" args:@{}];
  XCTAssertNil(products.delegate);
  XCTAssertNil(receipt.delegate);

  XCTestExpectation *drained = [self expectationWithDescription:@"Queued request delegates ran"];
  dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
  [self waitForExpectations:@[drained] timeout:2];
  XCTAssertEqual(productReplies.count, 1u);
  XCTAssertEqual(receiptReplies.count, 1u);
  FlutterError *productError = productReplies.firstObject;
  FlutterError *receiptError = receiptReplies.firstObject;
  XCTAssertEqualObjects(productError.code, @"observer_stopped");
  XCTAssertEqualObjects(receiptError.code, @"observer_stopped");
}

- (void)testCompletedRequestKeepsItsResultWhenObserverStops {
  TestPlugin *plugin = [TestPlugin new];
  plugin.fixture = [LocalQueue new];
  [self call:plugin method:@"start" args:@{}];
  HeldReceiptRequest *receipt = [[HeldReceiptRequest alloc] initWithReceiptProperties:nil];
  XCTestExpectation *completed = [self expectationWithDescription:@"Receipt refresh finished"];
  __block NSUInteger replies = 0;
  [plugin startRequest:receipt result:^(id value) {
    XCTAssertFalse([value isKindOfClass:FlutterError.class]);
    if (++replies == 1) [completed fulfill];
  }];
  [plugin requestDidFinish:receipt];
  [self waitForExpectations:@[completed] timeout:2];
  [self call:plugin method:@"stop" args:@{}];
  XCTAssertEqual(replies, 1u);
}

- (void)testDistinctRestoreEntriesKeepOriginalEvidence {
  LocalItem *original = [LocalItem item:SKPaymentTransactionStatePurchased];
  original.transactionIdentifier = @"paid";
  original.applicationUsername = @"original";
  LocalItem *a = [LocalItem item:SKPaymentTransactionStateRestored];
  LocalItem *b = [LocalItem item:SKPaymentTransactionStateRestored];
  a.transactionIdentifier = @"r1";
  b.transactionIdentifier = @"r2";
  a.originalTransaction = original;
  b.originalTransaction = original;
  TestPlugin *plugin = [TestPlugin new];
  plugin.fixture = [LocalQueue new];
  plugin.fixture.transactions = @[a, b];
  NSArray *items = [self call:plugin method:@"start" args:@{}][@"transactions"];
  XCTAssertEqualObjects([items valueForKey:@"transactionId"], (@[@"paid", @"paid"]));
  XCTAssertEqualObjects([items valueForKey:@"token"], (@[@"original", @"original"]));
  XCTAssertEqualObjects([items valueForKey:@"queueId"], (@[@"r1", @"r2"]));
  XCTAssertNotEqualObjects(items[0][@"handle"], items[1][@"handle"]);
  [plugin stopObserving];
}
@end
