/// Input for a trusted server verifier. An app receipt can cover several accounts.
class AppleReceipt {
  const AppleReceipt(
      {required this.scope,
      required this.orderId,
      required this.productId,
      required this.attemptId,
      required this.transactionId,
      required this.receipt,
      this.purchaseToken,
      this.originalTransactionId,
      this.additionalCharge = false});
  final String scope, orderId, productId, transactionId, receipt;
  final String? purchaseToken, originalTransactionId, attemptId;
  final bool additionalCharge;
}

enum AppleOutcome { delivered, refunded }

/// A terminal server receipt for this exact charge, after idempotent fulfillment.
class AppleDisposition {
  const AppleDisposition(
      {required this.appId,
      required this.environment,
      required this.scope,
      required this.orderId,
      required this.productId,
      required this.reportedTransactionId,
      required this.verifiedTransactionId,
      required this.reference,
      this.supersedes,
      this.quantity = 1,
      this.outcome = AppleOutcome.delivered});
  final String appId, environment, scope, orderId, productId;
  final String reportedTransactionId, verifiedTransactionId, reference;

  /// A verified refund or compensation can explicitly replace this receipt.
  final String? supersedes;
  final int quantity;
  final AppleOutcome outcome;
}

enum AppleVerificationKind {
  delivered,
  retryLater,
  invalidEvidence,
  environmentMismatch,
  needsReconciliation
}

/// Signed Apple facts checked by the trusted verifier before fulfillment.
class AppleEnvironmentMismatch {
  const AppleEnvironmentMismatch({
    required this.appId,
    required this.expectedEnvironment,
    required this.actualEnvironment,
    required this.reportedTransactionId,
    required this.verifiedTransactionId,
    required this.productId,
    required this.issuer,
    required this.reference,
    this.purchaseToken,
  });
  final String appId, expectedEnvironment, actualEnvironment;
  final String reportedTransactionId, verifiedTransactionId, productId;
  final String issuer, reference;

  /// UUID verified in the Apple transaction, if available.
  final String? purchaseToken;
}

class AppleVerification {
  const AppleVerification._(this.kind, {this.ack, this.mismatch});
  const AppleVerification.delivered(AppleDisposition ack)
      : this._(AppleVerificationKind.delivered, ack: ack);
  const AppleVerification.environmentMismatch(AppleEnvironmentMismatch proof)
      : this._(AppleVerificationKind.environmentMismatch, mismatch: proof);
  const AppleVerification.retryLater()
      : this._(AppleVerificationKind.retryLater);
  const AppleVerification.invalidEvidence()
      : this._(AppleVerificationKind.invalidEvidence);
  const AppleVerification.needsReconciliation()
      : this._(AppleVerificationKind.needsReconciliation);
  final AppleVerificationKind kind;
  final AppleDisposition? ack;
  final AppleEnvironmentMismatch? mismatch;
}

/// Server-authenticated binding. A missing original purchase token stays null.
class AppleClaim {
  const AppleClaim(
      {required this.appId,
      required this.environment,
      required this.scope,
      required this.orderId,
      required this.productId,
      required this.reportedTransactionId,
      required this.verifiedTransactionId,
      required this.reference,
      this.disposition,
      this.review,
      this.observationId,
      this.purchaseToken});
  final String appId, environment, scope, orderId, productId;
  final String reportedTransactionId, verifiedTransactionId, reference;
  final String? purchaseToken;

  /// A trusted recovery service can supply a missing or subsequent receipt.
  final AppleDisposition? disposition;
  final AppleDisputeReview? review;

  /// Stable application-level recovery reference returned by unmatched().
  final String? observationId;
}

/// An authenticated adjudicator's ruling on one revision of one dispute.
class AppleDisputeReview {
  const AppleDisputeReview({
    required this.issuer,
    required this.decisionId,
    required this.disputeId,
    required this.revision,
    required this.reference,
    this.coveredReceipts = const [],
    this.environmentProofId,
    this.finalDisposition,
  });
  final String issuer, decisionId, disputeId, reference;
  final int revision;
  final List<String> coveredReceipts;

  /// Selects a signed foreign-environment observation on this dispute.
  /// Omit to confirm the current environment. The destination requires its
  /// own verified claim and disposition before it can finish a queue item.
  final String? environmentProofId;
  final AppleDisposition? finalDisposition;
}

enum AppleAttemptOutcome { pending, unpaid, paid }

/// 'unpaid' requires authoritative, final evidence for this particular attempt.
class AppleAttemptDecision {
  const AppleAttemptDecision(
      {required this.issuer,
      required this.decisionId,
      required this.appId,
      required this.environment,
      this.attemptProof,
      required this.attemptId,
      required this.scope,
      required this.orderId,
      required this.reference,
      required this.outcome,
      this.claim});
  final String issuer, decisionId, appId, attemptId, scope, orderId, reference;
  final String environment;

  /// Independent server evidence linking the signed payment to a real submission.
  final String? attemptProof;
  final AppleAttemptOutcome outcome;
  final AppleClaim? claim;
}

/// The latest launch and the status of every charge on this business order.
class AppleOrderSnapshot {
  const AppleOrderSnapshot(
      {required this.scope,
      required this.orderId,
      required this.productId,
      required this.attemptId,
      required this.phase,
      required this.revision,
      required this.charges,
      this.unpaidFinishPending = false,
      this.reason});
  final String scope, orderId, productId, phase;
  final String? attemptId;
  final String? reason;
  final int revision;
  final List<AppleCharge> charges;

  /// A confirmed negative StoreKit event is still awaiting native cleanup.
  final bool unpaidFinishPending;
}

class AppleCharge {
  const AppleCharge(
      {required this.transactionId,
      required this.disposition,
      required this.reference,
      required this.finishPending,
      required this.conflict,
      this.reason});
  final String? transactionId, disposition, reference, reason;

  /// True until the SDK has recorded removal of every known StoreKit queue
  /// item for this charge. Also true when no queue item has been observed.
  /// If the app exits after removal but before recording it, this can stay
  /// true. For an undisputed charge, show the server's [disposition] as soon
  /// as it is available.
  final bool finishPending;
  final bool conflict;
}

/// Application-level recovery input. Keep this and raw receipts out of UI state.
class AppleTransaction {
  const AppleTransaction(
      {required this.id,
      required this.productId,
      required this.transactionId,
      required this.purchaseToken,
      required this.receipts,
      required this.observations,
      this.currentObservationIds = const {},
      this.disputeId,
      this.disputeRevision,
      this.receiptReferences = const [],
      this.environmentProofs = const {},
      this.environmentProof,
      this.reason});
  final String id, productId;
  final String? transactionId, purchaseToken, reason;
  final List<String> receipts;
  final Map<String, List<String>> observations;

  /// Observation IDs with a live StoreKit object at the time of this snapshot.
  final Set<String> currentObservationIds;
  final String? disputeId;
  final int? disputeRevision;
  final List<String> receiptReferences;

  /// Signed, still disputed environment facts by persistent observation ID.
  final Map<String, AppleEnvironmentMismatch> environmentProofs;
  final AppleEnvironmentMismatch? environmentProof;
}

/// Local submission evidence for the authenticated application recovery service.
/// A legacy attempt has no authenticated account until the service establishes it.
typedef AppleRecoveryAttempt = ({
  String attemptId,
  String? scope,
  String orderId,
  String productId,
  String? submittedToken,
  String phase,
  String? reason
});

/// Authenticated evidence of an exclusive pre-purchase token registration and
/// the Apple transaction that originally carried it. The issuer must verify
/// the original transaction, including the mapping of device and receipt IDs.
class AppleOriginalSubmission {
  const AppleOriginalSubmission({
    required this.issuer,
    required this.reference,
    required this.appId,
    required this.environment,
    required this.scope,
    required this.orderId,
    required this.productId,
    required this.quantity,
    required this.purchaseToken,
    required this.reportedTransactionId,
    required this.verifiedTransactionId,
  });
  final String issuer, reference, appId, environment, scope, orderId, productId;
  final int quantity;
  final String purchaseToken, reportedTransactionId, verifiedTransactionId;
}

/// A statement from the host's authenticated verifier about a single paid
/// consumable in the receipt for this observation. The verifier must establish
/// ownership from its own order records and authenticate the Apple transaction,
/// app, environment, product and quantity. A delivery receipt alone is insufficient.
class AppleVerifiedQueueTransaction {
  const AppleVerifiedQueueTransaction({
    required this.observationId,
    required this.receiptHash,
    required this.transactionId,
    required this.appId,
    required this.environment,
    required this.productId,
    required this.scope,
    required this.orderId,
    required this.quantity,
    required this.reference,
  });
  final String observationId, receiptHash, transactionId;
  final String appId, environment, productId, scope, orderId;
  final int quantity;

  /// Unique verifier reference for this observation.
  final String reference;
}

enum AppleObservationState {
  sourceUnproven,
  awaitingReplay,
  awaitingDisposition,
  awaitingRemoval,
  removed,
  disputed
}

/// State of one observation. A charge may be delivered while the source of
/// this particular item remains unknown. Recovery never submits a new purchase.
class AppleRecoveryResult {
  const AppleRecoveryResult(
      {required this.observationId,
      required this.state,
      this.scope,
      this.orderId,
      this.verifiedTransactionId,
      this.disposition,
      this.reference,
      this.reason});
  final String observationId;
  final AppleObservationState state;
  final String? scope,
      orderId,
      verifiedTransactionId,
      disposition,
      reference,
      reason;
}

class AppleAmbiguousObservation extends StateError {
  AppleAmbiguousObservation() : super('Apple observation source is ambiguous');
}
