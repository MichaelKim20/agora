/*******************************************************************************

    Implementation of the Node's API.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.node.Node;

import agora.api.Validator;
import agora.consensus.data.Block;
import agora.common.Amount;
import agora.common.BanManager;
import agora.common.Config;
import agora.common.Hash;
import agora.common.Metadata;
import agora.common.crypto.Key;
import agora.common.Task;
import agora.common.Types;
import agora.common.TransactionPool;
import agora.consensus.data.Enrollment;
import agora.consensus.data.PreimageInfo;
import agora.consensus.data.Transaction;
import agora.consensus.data.UTXOSet;
import agora.consensus.EnrollmentManager;
import agora.consensus.protocol.Nominator;
import agora.network.NetworkClient;
import agora.network.NetworkManager;
import agora.node.BlockStorage;
import agora.node.Ledger;
import agora.utils.Log;
import agora.utils.PrettyPrinter;

import scpd.types.Stellar_SCP;
import scpd.types.Utils;

import vibe.core.core;
import vibe.data.json;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

import ocean.util.log.Logger;

import std.algorithm;
import std.exception;
import std.file;
import std.path : buildPath;
import std.range;

mixin AddLogger!();

/// Maximum number of blocks that will be sent in a call to getBlocksFrom()
private enum uint MaxBatchBlocksSent = 1000;

/*******************************************************************************

    Implementation of the Node API

    This class implement the business code of the node.
    Communication with the other nodes is handled by the `Network` class.

*******************************************************************************/

public class Node : API
{
    /// Metadata instance
    protected Metadata metadata;

    /// Config instance
    protected const Config config;

    /// Task manager
    protected TaskManager taskman;

    /// Network of connected nodes
    protected NetworkManager network;

    /// Reusable exception object
    protected RestException exception;

    /// Transaction pool
    protected TransactionPool pool;

    /// Set of unspent transaction outputs
    protected UTXOSet utxo_set;

    ///
    protected Ledger ledger;

    /// Blockstorage
    protected IBlockStorage storage;

    /// Nominator instance
    protected Nominator nominator;

    /// Enrollment manager
    protected EnrollmentManager enroll_man;

    /// Ctor
    public this (const Config config)
    {
        this.metadata = this.getMetadata(config.node.data_dir);

        this.config = config;
        this.taskman = this.getTaskManager();
        this.network = this.getNetworkManager(config.node, config.banman,
            config.network, config.dns_seeds, this.metadata, this.taskman);
        this.storage = this.getBlockStorage(config.node.data_dir);
        this.pool = this.getPool(config.node.data_dir);
        scope (failure) this.pool.shutdown();
        this.utxo_set = this.getUtxoSet(config.node.data_dir);
        scope (failure) this.utxo_set.shutdown();
        this.ledger = new Ledger(this.pool, this.utxo_set, this.storage, config.node);
        this.enroll_man = this.getEnrollmentManager(config.node.data_dir, config.node);
        scope (failure) this.enroll_man.shutdown();
        this.exception = new RestException(
            400, Json("The query was incorrect"), string.init, int.init);

        if (this.config.node.is_validator)
            this.nominator = this.getNominator(this.config.node.key_pair,
                this.ledger, this.taskman, this.config.quorum);
    }

    /// The first task method, loading from disk, node discovery, etc
    public void start ()
    {
        log.info("Doing network discovery..");
        auto peers = this.network.discover();

        if (this.config.node.is_validator)
            this.nominator.setupNetwork(peers);

        bool isNominating ()
        {
            return this.config.node.is_validator &&
                this.nominator.isNominating();
        }

        this.network.startPeriodicCatchup(this.ledger, &isNominating);
    }

    /***************************************************************************

        Called on node shutdown.

        Note that this is called explicitly before any destructors,
        to allow clean shutdown of e.g. databases, which may require
        GC allocations during the shutdown phase.

    ***************************************************************************/

    public void shutdown ()
    {
        log.info("Shutting down..");
        this.network.dumpMetadata();
        this.pool.shutdown();
        this.pool = null;
        this.utxo_set.shutdown();
        this.utxo_set = null;
        this.enroll_man.shutdown();
        this.enroll_man = null;
    }

    /// GET /public_key
    public override PublicKey getPublicKey () pure nothrow @safe @nogc
    {
        return this.config.node.key_pair.address;
    }

    /// GET: /network_info
    public override NetworkInfo getNetworkInfo () pure nothrow @safe @nogc
    {
        return this.network.getNetworkInfo();
    }

    /***************************************************************************

        Receive a transaction.

        API:
            PUT /transaction

        Params:
            tx = the received transaction

    ***************************************************************************/

    public override void putTransaction (Transaction tx) @safe
    {
        log.trace("Received Transaction: {}", prettify(tx));

        auto tx_hash = hashFull(tx);
        if (this.ledger.hasTransactionHash(tx_hash))
            return;

        if (this.ledger.acceptTransaction(tx))
        {
            // gossip first
            this.network.sendTransaction(tx);

            // then nominate
            if (this.config.node.is_validator)
                this.nominator.tryNominate();
        }

        if (this.enroll_man.needRevealPreimage(this.ledger.getBlockHeight()))
        {
            PreimageInfo preimage;
            if (this.enroll_man.getNextPreimage(preimage))
            {
                this.receivePreimage(preimage);
                this.enroll_man.increaseNextRevealHeight();
            }
        }
    }

    /***************************************************************************

        Receive an SCP envelope.

        API:
            GET /envelope

        Params:
            envelope = the SCP envelope

        Returns:
            true if the envelope was accepted

    ***************************************************************************/

    public bool receiveEnvelope (SCPEnvelope envelope)
    {
        // we should not receive SCP messages unless we're a validator node
        if (!this.config.node.is_validator)
            return false;

        return this.nominator.receiveEnvelope(envelope);
    }

    /// GET: /has_transaction_hash
    public override bool hasTransactionHash (Hash tx) @safe
    {
        return this.ledger.hasTransactionHash(tx);
    }

    /// GET: /block_height
    public ulong getBlockHeight ()
    {
        return this.ledger.getBlockHeight();
    }

    /// GET: /blocks_from
    public const(Block)[] getBlocksFrom (ulong block_height, uint max_blocks)
        @safe
    {
        return this.ledger.getBlocksFrom(block_height)
            .take(min(max_blocks, MaxBatchBlocksSent)).array;
    }

    /***************************************************************************

        Returns an instance of a NetworkManager

        Unittests can override this method and return a custom NetworkManager.

        Params:
            node_config = the node config
            banman_conf = the ban manager config
            peers = the peers to connect to
            dns_seeds = the DNS seeds to retrieve peers from
            metadata = metadata containing known peers and other meta info
            taskman = task manager

        Returns:
            an instance of a NetworkManager

    ***************************************************************************/

    protected NetworkManager getNetworkManager (in NodeConfig node_config,
        in BanManager.Config banman_conf, in string[] peers,
        in string[] dns_seeds, Metadata metadata, TaskManager taskman)
    {
        return new NetworkManager(node_config, banman_conf, peers, dns_seeds,
            metadata, taskman);
    }

    /***************************************************************************

        Returns an instance of a TaskManager

        Subclasses can override this method and return
        a TaskManager backed by LocalRest.

        Returns:
            the task manager

    ***************************************************************************/

    protected TaskManager getTaskManager ()
    {
        return new TaskManager();
    }

    /***************************************************************************

        Returns an instance of a TransactionPool

        Subclasses can override this method and return
        a TransactionPool backed by an in-memory SQLite database.

        Params:
            data_dir = path to the data directory

        Returns:
            the transaction pool

    ***************************************************************************/

    protected TransactionPool getPool (string data_dir)
    {
        return new TransactionPool(buildPath(
            config.node.data_dir, "tx_pool.dat"));
    }

    /***************************************************************************

        Returns an instance of a UTXOSet

        Unittest code may override this method to provide a Utxo set
        that doesn't do any I/O.

        Params:
            data_dir = path to the data directory

        Returns:
            the UTXOSet instance

    ***************************************************************************/

    protected UTXOSet getUtxoSet (string data_dir)
    {
        return new UTXOSet(buildPath(config.node.data_dir, "utxo_set.dat"));
    }

    /***************************************************************************

        Reads the metadata from the provided disk path.

        Subclasses can override this method and return
        a Metadata object which loads/dumps data in memory
        rather than on disk, to avoid I/O (e.g. for unittesting)

        Note: not exposed in the API.

        Params:
            data_dir = path to the data directory

        Returns:
            the metadata loaded from disk

    ***************************************************************************/

    protected Metadata getMetadata (string data_dir) @system
    {
        return new DiskMetadata(data_dir);
    }

    /***************************************************************************

        Returns an instance of a BlockStorage or MemoryStorage

        Note: not exposed in the API.

        Params:
            data_dir = path to the blockdata directory

        Returns:
            Returns instance of `MemoryStorage` if data_dir is empty,
            otherwise returns instance of `BlockStorage`

    ***************************************************************************/

    protected IBlockStorage getBlockStorage (string data_dir) @system
    {
        version (unittest)
        {
            return new MemBlockStorage();
        }
        else
        {
            return new BlockStorage(data_dir);
        }
    }

    /***************************************************************************

        Returns an instance of a EnrollmentManager

        Params:
            data_dir = path to the data dirctory
            node_config = the node config

        Returns:
            the enrollment manager

    ***************************************************************************/

    protected EnrollmentManager getEnrollmentManager (string data_dir,
        in NodeConfig node_config)
    {
        return new EnrollmentManager(buildPath(data_dir, "validator_set.dat"),
            node_config.key_pair);
    }

    /***************************************************************************

        Returns an instance of a Nominator.

        Test-suites can inject a badly-behaved nominator in order to
        simulate byzantine nodes.

        Params:
            key_pair = the key pair of the node
            ledger = Ledger instance
            taskman = the task manager
            quorum_config = the SCP quorum set configuration

        Returns:
            An instance of a `Nominator`

    ***************************************************************************/

    protected Nominator getNominator (KeyPair key_pair, Ledger ledger,
        TaskManager taskman, in QuorumConfig quorum_config)
    {
        return new Nominator(key_pair, ledger, taskman, quorum_config);
    }

    /***************************************************************************

        Create an enrollment data for enrollment process

        Params:
            frozen_utxo_hash = the hash of a frozen UTXO used to identify
                        a validator or an enrollment data

        Returns:
            the Enrollment object created

    ***************************************************************************/

    protected Enrollment createEnrollment (Hash frozen_utxo_hash) @safe
    {
        Enrollment enroll;
        this.enroll_man.createEnrollment(frozen_utxo_hash, enroll);

        return enroll;
    }

    /// GET: /merkle_path
    public Hash[] getMerklePath (ulong block_height, Hash hash) @safe
    {
        return this.ledger.getMerklePath(block_height, hash);
    }

    /// PUT: /enroll_validator
    public void enrollValidator (Enrollment enroll) @safe
    {
        log.trace("Received Enrollment: {}", prettify(enroll));

        if (this.enroll_man.add(this.ledger.getBlockHeight(),
            this.utxo_set.getUTXOFinder(),
            enroll))
        {
            this.network.sendEnrollment(enroll);
        }
    }

    /// GET: /has_enrollment
    public bool hasEnrollment (Hash enroll_hash) @safe
    {
        return this.enroll_man.hasEnrollment(enroll_hash);
    }

    /// PUT: /receive_preimage
    public void receivePreimage (PreimageInfo preimage) @safe
    {
        log.trace("Received Preimage: {}", prettify(preimage));

        if (this.enroll_man.addPreimage(preimage))
            this.network.sendPreimage(preimage);
    }

    /// GET: /has_preimage
    public bool hasPreimage (Hash enroll_key, ulong height)
    {
        return this.enroll_man.hasPreimage(enroll_key, height);
    }
}


/*******************************************************************************

    Boots up a node that listen for network requests and blockchain data

    This is called from the main or CLI.
    The initialization process of the node is then completed.

    Params:
      config = A parsed and validated config file

*******************************************************************************/

public Node runNode (Config config)
{
    Log.root.level(config.logging.log_level, true);
    log.trace("Config is: {}", config);

    auto settings = new HTTPServerSettings(config.node.address);
    settings.port = config.node.port;
    auto router = new URLRouter();

    mkdirRecurse(config.node.data_dir);

    auto node = new Node(config);
    router.registerRestInterface(node);
    runTask({ node.start(); });

    log.info("About to listen to HTTP: {}", settings.port);
    listenHTTP(settings, router);
    return node;
}
