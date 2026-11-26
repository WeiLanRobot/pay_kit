// Each pending purchase is its own durable work item. Only changes to verifier
// inputs advance its revision. Retrying or replaying the same event does not.
const workerColumns = [
  'ALTER TABLE purchase ADD COLUMN inputVersion INTEGER NOT NULL DEFAULT 1',
  'ALTER TABLE purchase ADD COLUMN blockedLogin TEXT',
  'ALTER TABLE purchase_evidence ADD COLUMN storeObserved INTEGER NOT NULL DEFAULT 1',
];

const workerTables = [
  '''CREATE TABLE purchase_redirect(
       id TEXT PRIMARY KEY, purchaseId TEXT NOT NULL REFERENCES purchase(id))''',
  '''CREATE TABLE evidence_source(
       hash TEXT NOT NULL REFERENCES evidence(hash) ON DELETE CASCADE,
       source TEXT NOT NULL, context TEXT NOT NULL,
       PRIMARY KEY(hash,source,context))''',
  '''CREATE TABLE legacy_handoff(
       purchaseId TEXT PRIMARY KEY REFERENCES purchase(id),
       attemptId TEXT NOT NULL REFERENCES attempt(id), hash TEXT NOT NULL)''',
  '''CREATE TRIGGER purchase_input AFTER UPDATE OF scope,orderId,attemptId,token,
       originalId,reportedId,verifiedId,claimRef,conflict ON purchase
       WHEN OLD.scope IS NOT NEW.scope OR OLD.orderId IS NOT NEW.orderId OR
         OLD.attemptId IS NOT NEW.attemptId OR OLD.token IS NOT NEW.token OR
         OLD.originalId IS NOT NEW.originalId OR OLD.reportedId IS NOT NEW.reportedId OR
         OLD.verifiedId IS NOT NEW.verifiedId OR OLD.claimRef IS NOT NEW.claimRef OR
         OLD.conflict IS NOT NEW.conflict
       BEGIN
         UPDATE purchase SET inputVersion=inputVersion+1,blockedLogin=NULL,
           reason=CASE WHEN conflict=0 AND reason IN
             ('needsReconciliation','invalidEvidence','verificationRetry') THEN NULL ELSE reason END
           WHERE id=NEW.id;
         UPDATE purchase_evidence SET rejected=0,tried=0 WHERE purchaseId=NEW.id;
       END''',
  '''CREATE TRIGGER purchase_candidate AFTER INSERT ON purchase_evidence
       BEGIN
         UPDATE purchase SET inputVersion=inputVersion+1,blockedLogin=NULL,
           reason=CASE WHEN conflict=0 AND reason IN
             ('needsReconciliation','invalidEvidence','verificationRetry') THEN NULL ELSE reason END
           WHERE id=NEW.purchaseId;
       END''',
];
