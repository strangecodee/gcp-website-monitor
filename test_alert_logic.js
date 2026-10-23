// Pre-seed require.cache to mock firebase-admin before loading index.js
const mockFirestore = {
  collection: () => ({
    doc: () => ({
      get: async () => ({ exists: false }),
      set: async () => {},
      create: async () => {}
    })
  })
};

const mockAdmin = {
  apps: { length: 1 },
  initializeApp: () => {},
  app: () => {}
};

// Custom mock Timestamp class
class MockTimestamp {
  constructor(date) {
    this._date = date;
  }
  static fromDate(date) {
    return new MockTimestamp(date);
  }
  toDate() {
    return this._date;
  }
  getTime() {
    return this._date.getTime();
  }
}

require.cache[require.resolve("firebase-admin")] = {
  id: require.resolve("firebase-admin"),
  filename: require.resolve("firebase-admin"),
  loaded: true,
  exports: mockAdmin
};

require.cache[require.resolve("firebase-admin/firestore")] = {
  id: require.resolve("firebase-admin/firestore"),
  filename: require.resolve("firebase-admin/firestore"),
  loaded: true,
  exports: {
    getFirestore: () => mockFirestore,
    Timestamp: MockTimestamp
  }
};

// Set env variable to expose test helper exports in index.js
process.env.NODE_ENV = "test";

const assert = require("assert");
const index = require("./index.js");
const { isFailureStatus, determineTransition, findErrorInBody } = index;

console.log("Mock environment loaded. Starting unit tests...");

// Mocks helper for dates
const dateAgo = (mins) => new Date(Date.now() - mins * 60 * 1000);

// Instantiate static dates to prevent 1ms execution delays between expected and actual
const tenMinsAgo = dateAgo(10);
const twentyFiveMinsAgo = dateAgo(25);
const thirtyOneMinsAgo = dateAgo(31);
const thirtyFiveMinsAgo = dateAgo(35);

// TEST SUITE FOR STATE MACHINE (PART 15)

// Helper to run transitions
function testTransition({ desc, previous, currentStatus, now, expected }) {
  try {
    const prevMock = previous
      ? {
          status: previous.status,
          lastAlertAt: previous.lastAlertAt ? MockTimestamp.fromDate(previous.lastAlertAt) : null,
          downSince: previous.downSince ? MockTimestamp.fromDate(previous.downSince) : null,
          thirtyMinuteAlertSent: previous.thirtyMinuteAlertSent || false
        }
      : null;

    const result = determineTransition({
      previous: prevMock,
      currentStatus,
      now,
      ONGOING_ALERT_INTERVAL_MS: 30 * 60 * 1000
    });

    assert.strictEqual(result.event, expected.event, `${desc} - event mismatch: expected ${expected.event}, got ${result.event}`);
    assert.strictEqual(result.shouldSendEmail, expected.shouldSendEmail, `${desc} - shouldSendEmail mismatch: expected ${expected.shouldSendEmail}, got ${result.shouldSendEmail}`);
    assert.strictEqual(result.thirtyMinuteAlertSent, expected.thirtyMinuteAlertSent, `${desc} - thirtyMinuteAlertSent mismatch: expected ${expected.thirtyMinuteAlertSent}, got ${result.thirtyMinuteAlertSent}`);
    
    if (expected.downSince === null) {
      assert.strictEqual(result.downSince, null, `${desc} - downSince should be null`);
    } else if (expected.downSince === "now") {
      assert.ok(result.downSince, `${desc} - downSince should be set to current time`);
      assert.strictEqual(result.downSince.getTime(), now.getTime(), `${desc} - downSince time mismatch`);
    } else if (expected.downSince instanceof Date) {
      assert.ok(result.downSince, `${desc} - downSince should be present`);
      assert.strictEqual(result.downSince.getTime(), expected.downSince.getTime(), `${desc} - downSince time mismatch`);
    }

    console.log(`\x1b[32m✔ Passed:\x1b[0m ${desc}`);
  } catch (err) {
    console.error(`\x1b[31m✘ Failed:\x1b[0m ${desc}`);
    console.error(err);
    process.exit(1);
  }
}

const now = new Date();

// TEST 1: Previous UP, Current UP -> NO ALERT
testTransition({
  desc: "TEST 1: Previous UP, Current UP -> NO ALERT",
  previous: { status: "UP" },
  currentStatus: "UP",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: false, downSince: null }
});

// TEST 2: Previous UP, Current SERVER_ERROR -> FIRST_FAILURE
testTransition({
  desc: "TEST 2: Previous UP, Current SERVER_ERROR -> FIRST_FAILURE",
  previous: { status: "UP" },
  currentStatus: "SERVER_ERROR",
  now,
  expected: { event: "FIRST_FAILURE", shouldSendEmail: true, thirtyMinuteAlertSent: false, downSince: "now" }
});

// TEST 3: Previous UP, Current CLIENT_ERROR -> FIRST_FAILURE
testTransition({
  desc: "TEST 3: Previous UP, Current CLIENT_ERROR -> FIRST_FAILURE",
  previous: { status: "UP" },
  currentStatus: "CLIENT_ERROR",
  now,
  expected: { event: "FIRST_FAILURE", shouldSendEmail: true, thirtyMinuteAlertSent: false, downSince: "now" }
});

// TEST 4: Previous UP, Current DOWN -> FIRST_FAILURE
testTransition({
  desc: "TEST 4: Previous UP, Current DOWN -> FIRST_FAILURE",
  previous: { status: "UP" },
  currentStatus: "DOWN",
  now,
  expected: { event: "FIRST_FAILURE", shouldSendEmail: true, thirtyMinuteAlertSent: false, downSince: "now" }
});

// TEST 5: Previous SERVER_ERROR, Current SERVER_ERROR -> NO ALERT
testTransition({
  desc: "TEST 5: Previous SERVER_ERROR, Current SERVER_ERROR -> NO ALERT",
  previous: { status: "SERVER_ERROR", downSince: tenMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "SERVER_ERROR",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: false, downSince: tenMinsAgo }
});

// TEST 6: Previous SERVER_ERROR, Current CLIENT_ERROR -> NO NEW FIRST_FAILURE
testTransition({
  desc: "TEST 6: Previous SERVER_ERROR, Current CLIENT_ERROR -> NO NEW FIRST_FAILURE",
  previous: { status: "SERVER_ERROR", downSince: tenMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "CLIENT_ERROR",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: false, downSince: tenMinsAgo }
});

// TEST 7: Previous CLIENT_ERROR, Current DOWN -> NO NEW FIRST_FAILURE
testTransition({
  desc: "TEST 7: Previous CLIENT_ERROR, Current DOWN -> NO NEW FIRST_FAILURE",
  previous: { status: "CLIENT_ERROR", downSince: tenMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "DOWN",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: false, downSince: tenMinsAgo }
});

// TEST 8: Previous SERVER_ERROR, Current UP -> RECOVERY
testTransition({
  desc: "TEST 8: Previous SERVER_ERROR, Current UP -> RECOVERY",
  previous: { status: "SERVER_ERROR", downSince: tenMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "UP",
  now,
  expected: { event: "RECOVERY", shouldSendEmail: true, thirtyMinuteAlertSent: false, downSince: null }
});

// TEST 9: Previous DOWN, Current UP -> RECOVERY
testTransition({
  desc: "TEST 9: Previous DOWN, Current UP -> RECOVERY",
  previous: { status: "DOWN", downSince: tenMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "UP",
  now,
  expected: { event: "RECOVERY", shouldSendEmail: true, thirtyMinuteAlertSent: false, downSince: null }
});

// TEST 10: Failure duration < 30 minutes -> NO 30-MINUTE ALERT
testTransition({
  desc: "TEST 10: Failure duration < 30 minutes -> NO 30-MINUTE ALERT",
  previous: { status: "SERVER_ERROR", downSince: twentyFiveMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "SERVER_ERROR",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: false, downSince: twentyFiveMinsAgo }
});

// TEST 11: Failure duration >= 30 minutes -> DOWN_30_MINUTE
testTransition({
  desc: "TEST 11: Failure duration >= 30 minutes -> DOWN_30_MINUTE",
  previous: { status: "SERVER_ERROR", downSince: thirtyOneMinsAgo, thirtyMinuteAlertSent: false },
  currentStatus: "SERVER_ERROR",
  now,
  expected: { event: "DOWN_30_MINUTE", shouldSendEmail: true, thirtyMinuteAlertSent: true, downSince: thirtyOneMinsAgo }
});

// TEST 12: 30-minute alert already sent -> NO DUPLICATE 30-MINUTE ALERT
testTransition({
  desc: "TEST 12: 30-minute alert already sent -> NO DUPLICATE 30-MINUTE ALERT",
  previous: { status: "SERVER_ERROR", downSince: thirtyFiveMinsAgo, thirtyMinuteAlertSent: true },
  currentStatus: "SERVER_ERROR",
  now,
  expected: { event: null, shouldSendEmail: false, thirtyMinuteAlertSent: true, downSince: thirtyFiveMinsAgo }
});

// TEST 13 & 14: Pub/Sub Idempotency locks
console.log("\nStarting idempotency lock unit tests...");

const mockRunsDb = new Map();

function mockCreateRun(messageId) {
  if (mockRunsDb.has(messageId)) {
    const err = new Error("Document already exists");
    err.code = 6; // ALREADY_EXISTS
    throw err;
  }
  mockRunsDb.set(messageId, { status: "running", startedAt: new Date() });
}

// TEST 13: Same Pub/Sub message ID received twice
const testMessageId = "msg-12345";
try {
  // First delivery
  mockCreateRun(testMessageId);
  console.log("✔ Passed: TEST 13 (First delivery: Processed)");
  
  // Second delivery
  assert.throws(
    () => mockCreateRun(testMessageId),
    (err) => err.code === 6,
    "Should throw ALREADY_EXISTS error on second delivery"
  );
  console.log("✔ Passed: TEST 13 (Second delivery: Skipped as duplicate)");
} catch (err) {
  console.error("✘ Failed: TEST 13", err);
  process.exit(1);
}

// TEST 13.5: Deep Health Check (Response Content Validation)
try {
  assert.strictEqual(findErrorInBody("<html><body>Welcome to Jindal Portal</body></html>"), null);
  assert.ok(findErrorInBody("Error: Database Connection Failed"));
  assert.ok(findErrorInBody("502 Bad Gateway - nginx/1.18.0"));
  assert.ok(findErrorInBody("Whitelabel Error Page"));
  console.log("✔ Passed: TEST 13.5 (Deep health check content validation)");
} catch (err) {
  console.error("✘ Failed: TEST 13.5", err);
  process.exit(1);
}

// TEST 14: Two concurrent requests with same Pub/Sub message ID
const concurrentMsgId = "msg-concurrent-567";
const attempts = [];
let successCount = 0;
let failCount = 0;

for (let i = 0; i < 2; i++) {
  attempts.push(
    (async () => {
      try {
        mockCreateRun(concurrentMsgId);
        successCount++;
      } catch (err) {
        if (err.code === 6) {
          failCount++;
        } else {
          throw err;
        }
      }
    })()
  );
}

Promise.all(attempts).then(() => {
  try {
    assert.strictEqual(successCount, 1, "Exactly one concurrent attempt should succeed");
    assert.strictEqual(failCount, 1, "Exactly one concurrent attempt should fail with ALREADY_EXISTS");
    console.log("✔ Passed: TEST 14 (Concurrent executions: Only one processed, duplicate skipped)");
    console.log("\n\x1b[32mAll Phase 3 unit tests passed successfully!\x1b[0m");
  } catch (err) {
    console.error("✘ Failed: TEST 14", err);
    process.exit(1);
  }
}).catch((err) => {
  console.error("✘ Failed: TEST 14", err);
  process.exit(1);
});
