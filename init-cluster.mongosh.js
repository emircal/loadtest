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
  const { dbName, sites } = resolveArgs();

  if (!dbName) {
    throw new Error('Usage: INIT_CLUSTER_DB_NAME=<db-name> [INIT_CLUSTER_SITES=<count>] mongosh <uri> init-cluster.mongosh.js');
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
  ensureIndex(targetDb.collections, { accountId: 1, collectionId: 1 }, { name: 'accountId_1_collectionId_1' });

  runAdmin({ enableSharding: dbName }, ['already enabled']);
  runAdmin({ shardCollection: `${dbName}.accounts`, key: { accountId: 1 } }, ['already sharded']);
  runAdmin({ shardCollection: `${dbName}.transactions`, key: { accountId: 1, transactionId: 1 } }, ['already sharded']);
  runAdmin({ shardCollection: `${dbName}.collections`, key: { accountId: 1, collectionId: 1 } }, ['already sharded']);

  const splitPoints = buildAccountBoundaries(shardNames.length, sites);
  print(`Using ${splitPoints.length} split point(s) to distribute data across ${shardNames.length} shard(s).`);

  preSplitAndDistribute({
    namespace: `${dbName}.accounts`,
    splitPoints: splitPoints.map((accountId) => ({ accountId })),
    chunkStarts: [
      { accountId: MinKey },
      ...splitPoints.map((accountId) => ({ accountId }))
    ],
    shardNames
  });

  preSplitAndDistribute({
    namespace: `${dbName}.transactions`,
    splitPoints: splitPoints.map((accountId) => ({ accountId, transactionId: MinKey })),
    chunkStarts: [
      { accountId: MinKey, transactionId: MinKey },
      ...splitPoints.map((accountId) => ({ accountId, transactionId: MinKey }))
    ],
    shardNames
  });

  preSplitAndDistribute({
    namespace: `${dbName}.collections`,
    splitPoints: splitPoints.map((accountId) => ({ accountId, collectionId: MinKey })),
    chunkStarts: [
      { accountId: MinKey, collectionId: MinKey },
      ...splitPoints.map((accountId) => ({ accountId, collectionId: MinKey }))
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
    return normalizeArgs(injected.dbName, injected.sites);
  }

  if (env && env.INIT_CLUSTER_DB_NAME) {
    return normalizeArgs(env.INIT_CLUSTER_DB_NAME, env.INIT_CLUSTER_SITES);
  }

  if (argv.length > 0) {
    return parseLegacyArgs(argv);
  }

  return { dbName: '', sites: 1 };
}

function parseLegacyArgs(args) {
  const dbName = args[0];
  let sites = 1;

  for (let i = 1; i < args.length; i += 1) {
    if (args[i] === '--sites') {
      if (i + 1 >= args.length) {
        throw new Error('--sites requires a value');
      }

      sites = Number(args[i + 1]);
      i += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${args[i]}`);
  }

  return normalizeArgs(dbName, sites);
}

function normalizeArgs(dbName, sitesValue) {
  const sites = sitesValue === undefined || sitesValue === '' ? 1 : Number(sitesValue);

  if (!Number.isInteger(sites) || sites < 1) {
    throw new Error(`sites must be a positive integer. Got: ${sitesValue}`);
  }

  return { dbName, sites };
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

function buildAccountBoundaries(shardCount, sites) {
  if (shardCount <= 1) {
    return [];
  }

  // Generate shardCount-1 split points distributed across sites' key ranges.
  // Each chunk position (1 to shardCount-1) is placed within the appropriate site's range.
  //
  // Example: 3 shards, 1 site (S=1, R=3):
  //   Chunk positions: 1/3, 2/3 → SITE1_3, SITE1_6
  //
  // Example: 3 shards, 2 sites (S=2, R=3):
  //   Chunk 1/3 lands in SITE1 (0-50% of space) at 2/3 within SITE1 → SITE1_6
  //   Chunk 2/3 lands in SITE2 (50-100% of space) at 1/3 within SITE2 → SITE2_3

  const points = [];

  for (let chunkIdx = 1; chunkIdx < shardCount; chunkIdx += 1) {
    // Fraction of total key space at this chunk boundary
    const fractionOfTotal = chunkIdx / shardCount;

    // Which site does this chunk boundary fall into?
    // (sites are numbered 1..S, each occupying 1/S of the space)
    const siteIdx = Math.floor(fractionOfTotal * sites) + 1;

    // Position within that site's key range [0, 1)
    const siteStart = (siteIdx - 1) / sites;
    const fractionWithinSite = (fractionOfTotal - siteStart) * sites;

      const digit = Math.floor(fractionWithinSite * 10).toString();
    const suffix = digit.padEnd(16, digit);

    points.push(`SITE${siteIdx}_${suffix}`);
  }

  return points;
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
