import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pay_kit/pay_kit.dart';

/// Simulates the trusted server checking a line in this observation's receipt.
Future<AppleRecoveryResult> proveQueue(
    ApplePayments payments, AppleClaim claim) async {
  final item = (await payments.unmatched()).singleWhere((row) =>
      row.transactionId == claim.reportedTransactionId &&
      row.currentObservationIds.isNotEmpty);
  final id = claim.observationId ?? item.currentObservationIds.single;
  final receipt = item.observations[id]!.first;
  return payments.recoverObservation(
      AppleClaim(
        appId: claim.appId,
        environment: claim.environment,
        scope: claim.scope,
        orderId: claim.orderId,
        productId: claim.productId,
        reportedTransactionId: claim.reportedTransactionId,
        verifiedTransactionId: claim.verifiedTransactionId,
        reference: claim.reference,
        observationId: id,
        disposition: claim.disposition,
      ),
      verifiedQueueTransaction: AppleVerifiedQueueTransaction(
        observationId: id,
        transactionId: claim.verifiedTransactionId,
        appId: claim.appId,
        environment: claim.environment,
        productId: claim.productId,
        scope: claim.scope,
        orderId: claim.orderId,
        quantity: 1,
        receiptHash: sha256.convert(utf8.encode(receipt)).toString(),
        reference: 'proof-$id',
      ));
}
