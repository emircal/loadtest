// Usage:
//   INIT_CLUSTER_DB_NAME=<db-name> INIT_CLUSTER_SITES=<count> \
//     mongosh <connection-string> init-cluster.mongosh.js
//
// Example:
//   INIT_CLUSTER_DB_NAME=simrunner mongosh "mongodb://localhost:27017" init-cluster.mongosh.js
//   INIT_CLUSTER_DB_NAME=simrunner INIT_CLUSTER_SITES=3 \
//     mongosh "mongodb://localhost:27017" init-cluster.mongosh.js
//
// The script:
//   1. Creates the target database and collections if needed
//   2. Creates the shard key supporting indexes
//   3. Enables sharding on the database
//   4. Shards the collections using the same keys as the SimRunner configs
//   5. Pre-splits the collections across the shard key range and moves one chunk
//      to each shard so inserts can fan out immediately

(function main() {
  const { dbName } = resolveArgs();

  if (!dbName) {
    throw new Error('Usage: INIT_CLUSTER_DB_NAME=<db-name> mongosh <uri> init-cluster.mongosh.js');
  }

  const adminDb = db.getSiblingDB('admin');
  const targetDb = db.getSiblingDB(dbName);
  const shardNames = getShardNames(adminDb);

  if (shardNames.length === 0) {
    throw new Error('No shards found in the cluster.');
  }

  print(`Preparing database ${dbName} across ${shardNames.length} shard(s): ${shardNames.join(', ')}`);

  ensureCollection(targetDb, 'accounts');
  ensureCollection(targetDb, 'transactions');
  ensureCollection(targetDb, 'collections');

  ensureIndex(targetDb.accounts, { accountId: 1 }, { name: 'accountId_1' });
  ensureIndex(targetDb.transactions, { accountId: 1, transactionId: 1 }, { name: 'accountId_1_transactionId_1' });
  ensureIndex(targetDb.transactions, { accountId: 1, 'transactionDetails.postDate': -1 }, { name: 'accountId_1_postDate_-1' });
  ensureIndex(targetDb.collections, { accountId: 1, collectionId: 1 }, { name: 'accountId_1_collectionId_1' });

  runAdmin({ enableSharding: dbName }, ['already enabled']);
  runAdmin({ shardCollection: `${dbName}.accounts`, key: { accountId: 1 } }, ['already sharded']);
  runAdmin({ shardCollection: `${dbName}.transactions`, key: { accountId: 1, transactionId: 1 } }, ['already sharded']);
  runAdmin({ shardCollection: `${dbName}.collections`, key: { accountId: 1, collectionId: 1 } }, ['already sharded']);

  const splitPrefixes = buildShardPrefixBoundaries(shardNames.length);
  print(`Using ${splitPrefixes.length} split point(s) to distribute data across ${shardNames.length} shard(s).`);

  preSplitAndDistribute({
    namespace: `${dbName}.accounts`,
    splitPoints: splitPrefixes.map((prefix) => ({ accountId: prefix })),
    chunkStarts: [
      { accountId: MinKey },
      ...splitPrefixes.map((prefix) => ({ accountId: prefix }))
    ],
    shardNames
  });

  preSplitAndDistribute({
    namespace: `${dbName}.transactions`,
    splitPoints: splitPrefixes.map((prefix) => ({ accountId: prefix, transactionId: MinKey })),
    chunkStarts: [
      { accountId: MinKey, transactionId: MinKey },
      ...splitPrefixes.map((prefix) => ({ accountId: prefix, transactionId: MinKey }))
    ],
    shardNames
  });

  preSplitAndDistribute({
    namespace: `${dbName}.collections`,
    splitPoints: splitPrefixes.map((prefix) => ({ accountId: prefix, collectionId: MinKey })),
    chunkStarts: [
      { accountId: MinKey, collectionId: MinKey },
      ...splitPrefixes.map((prefix) => ({ accountId: prefix, collectionId: MinKey }))
    ],
    shardNames
  });

  runAdmin({ setAllowMigrations: `${dbName}.accounts`, allowMigrations: false }, ['already disabled']);
  runAdmin({ setAllowMigrations: `${dbName}.transactions`, allowMigrations: false }, ['already disabled']);
  runAdmin({ setAllowMigrations: `${dbName}.collections`, allowMigrations: false }, ['already disabled']);

  print('Cluster initialization complete.');
})();

function getShardNames(adminDb) {
  const result = adminDb.runCommand({ listShards: 1 });
  if (!result.ok) {
    throw new Error(`listShards failed: ${tojson(result)}`);
  }
  return result.shards.map((shard) => shard._id);
}

function resolveArgs() {
  const env = typeof process !== 'undefined' ? process.env : {};
  const injected = typeof globalThis !== 'undefined' ? globalThis.INIT_CLUSTER_ARGS : undefined;
  const argv = typeof process !== 'undefined' ? process.argv.slice(2) : [];

  if (injected && typeof injected === 'object') {
    return normalizeArgs(injected.dbName);
  }

  if (env && env.INIT_CLUSTER_DB_NAME) {
    return normalizeArgs(env.INIT_CLUSTER_DB_NAME);
  }

  if (argv.length > 0) {
    return parseLegacyArgs(argv);
  }

  return { dbName: '' };
}

function parseLegacyArgs(args) {
  const dbName = args[0];

  for (let i = 1; i < args.length; i += 1) {
    throw new Error(`Unknown argument: ${args[i]}`);
  }

  return normalizeArgs(dbName);
}

function normalizeArgs(dbName) {
  return { dbName };
}

function ensureCollection(database, collectionName) {
  const exists = database.getCollectionInfos({ name: collectionName }).length > 0;
  if (!exists) {
    database.createCollection(collectionName);
    print(`Created collection ${database.getName()}.${collectionName}`);
  }
}

function ensureIndex(collection, key, options) {
  collection.createIndex(key, options || {});
}

function runAdmin(command, ignorableMessageParts) {
  const ignorable = ignorableMessageParts || [];
  const result = db.adminCommand(command);
  if (result.ok) {
    return result;
  }

  const message = String(result.errmsg || result.note || tojson(result));
  if (ignorable.some((part) => message.includes(part))) {
    print(`Skipping non-fatal admin command result for ${Object.keys(command)[0]}: ${message}`);
    return result;
  }

  throw new Error(`Admin command failed ${tojson(command)}: ${message}`);
}

// Generates shardCount-1 shard-prefix split points: ["SHD1_", "SHD2_", ..., "SHD{N-1}_"].
// accountIds use the format "SHD{seq%S}_S{site}_{seq}" so each prefix bucket maps
// deterministically to one shard, avoiding hot-shard write concentration.
// Supports up to 9 shards (single-digit prefix keeps correct string sort order).
function buildShardPrefixBoundaries(shardCount) {
  if (shardCount <= 1) {
    return [];
  }
  const boundaries = [];
  for (let k = 1; k < shardCount; k++) {
    boundaries.push(`SHD${k}_`);
  }
  return boundaries;
}

function preSplitAndDistribute({ namespace, splitPoints, chunkStarts, shardNames }) {
  splitPoints.forEach((middle) => {
    runAdmin({ split: namespace, middle }, ['already split', 'is already on a boundary', 'cannot split on initial or final key']);
  });

  chunkStarts.forEach((findKey, index) => {
    const shardName = shardNames[index % shardNames.length];
    runAdmin(
      { moveChunk: namespace, find: findKey, to: shardName },
      ['that chunk is already on that shard', 'chunk is already on the destination shard']
    );
  });

  print(`Prepared ${namespace} with ${chunkStarts.length} chunk range(s).`);
}
