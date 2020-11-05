/*******************************************************************************

    Contains the base class for a UTXO set and an AA-backed UTXO set.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.state.UTXOSet;

import agora.common.crypto.Key;
import agora.common.Hash;
import agora.common.Serializer;
import agora.common.Set;
import agora.common.Types;
import agora.consensus.data.Transaction;
public import agora.consensus.data.UTXO;
import agora.utils.Log;

import std.file;

mixin AddLogger!();

/// Delegate to find an unspent UTXO
public alias UTXOFinder = bool delegate (Hash utxo, out UTXO) nothrow @safe;

/*******************************************************************************

    UTXOCache is the the base class of a UTXO storage.
    It is inherited by UTXOSet and TestUTXOSet.

*******************************************************************************/

abstract class UTXOCache
{
    /// Keeps track of spent outputs during the validation of a Tx / Block
    private Set!Hash used_utxos;

    /***************************************************************************

        Add all of a transaction's outputs to the Utxo set,
        and remove the spent outputs in the transaction from the set.

        Params:
            tx = the transaction
            height = local height of the block

    ***************************************************************************/

    public void updateUTXOCache (const ref Transaction tx, Height height) @safe
    {
        import std.algorithm : any;

        // defaults to next block
        Height unlock_height = Height(height + 1);

        // for payments of frozen transactions, it will melt after 2016 blocks
        if ((tx.type == TxType.Payment)
            && tx.inputs.any!(input =>
                (
                    (this.getUTXO(input.utxo).type == TxType.Freeze)
                )
            )
        )
        {
            unlock_height = Height(height + 2016);
        }

        foreach (const ref input; tx.inputs)
        {
            this.remove(input.utxo);
        }

        Hash tx_hash = tx.hashFull();
        foreach (idx, output; tx.outputs)
        {
            auto utxo_hash = UTXO.getHash(tx_hash, idx);
            auto utxo_value = UTXO(unlock_height, tx.type, output);
            this.add(utxo_hash, utxo_value);
        }
    }

    /***************************************************************************

        Get an UTXO from the UTXO set.

        Params:
            utxo = the hash of the UTXO to get

        Return:
            Return UTXO

    ***************************************************************************/

    protected UTXO getUTXO (Hash utxo) nothrow @safe
    {
        UTXO value;
        if (!this.peekUTXO(utxo, value))
            assert(0);
        return value;
    }

    /***************************************************************************

        Prepare tracking double-spent transactions and
        return the UTXOFinder delegate

        Returns:
            the UTXOFinder delegate

    ***************************************************************************/

    public UTXOFinder getUTXOFinder () nothrow @trusted
    {
        this.used_utxos.clear();
        return &this.findUTXO;
    }

    /***************************************************************************

        Get an UTXO, does not return double spend.

        Params:
            hash = the hash of the UTXO (`hashMulti(tx_hash, index)`)
            output = will contain the UTXO if found

        Return:
            Return true if the UTXO was found

    ***************************************************************************/

    public bool findUTXO (Hash utxo, out UTXO value) nothrow @safe
    {
        if (utxo in this.used_utxos)
        {
            log.trace("findUTXO: utxo_hash {} found in used_utxos: {}", utxo, used_utxos);
            return false;  // double-spend
        }

        if (this.peekUTXO(utxo, value))
        {
            this.used_utxos.put(utxo);
            return true;
        }
        log.trace("findUTXO: utxo_hash {} not found", utxo);
        return false;
    }

    /***************************************************************************

        Get an UTXO, no double-spend protection.

        Params:
            hash = the hash of the UTXO (`hashMulti(tx_hash, index)`)
            value = the UTXO

    ***************************************************************************/

    public abstract bool peekUTXO (Hash utxo, out UTXO value) nothrow @safe;

    /***************************************************************************

        Helper function to remove an UTXO in the UTXO set.

        Params:
            hash = the hash of the UTXO (`hashMulti(tx_hash, index)`)

    ***************************************************************************/

    protected abstract void remove (Hash utxo) @safe;

    /***************************************************************************

        Helper function to add an UTXO in the UTXO set.

        Params:
            hash = the hash of the UTXO (`hashMulti(tx_hash, index)`)
            value = the UTXO

    ***************************************************************************/

    protected abstract void add (Hash utxo, UTXO value) @safe;
}

/*******************************************************************************

    This is a simple UTXOSet, used when the AA behavior is desired

    Most unittests do not need a fully-fledged UTXOSet with all the DB and
    serialization that comes with it, instead relying on an associative array
    and a delegate.

    Since this pattern is so common, this class is offered as a mean to achieve
    this without code duplication. See issue #501 for history.

    Note that this should *NOT* be used to replace the above UTXOSet,
    when for example doing integration tests with LocalRest.

*******************************************************************************/

public class TestUTXOSet : UTXOCache
{
    /// UTXO cache backed by an AA
    public UTXO[Hash] storage;

    ///
    alias storage this;

    /// Short hand to add a transaction
    public void put (const Transaction tx) nothrow @safe
    {
        Hash txhash = hashFull(tx);
        foreach (size_t idx, ref output_; tx.outputs)
        {
            Hash h = UTXO.getHash(txhash, idx);
            UTXO v = {
                type: tx.type,
                output: output_
            };
            this.storage[h] = v;
        }
    }

    /// Workaround 20559...
    public void clear ()
    {
        this.storage.clear();
    }

    ///
    public override bool peekUTXO (Hash utxo, out UTXO value) nothrow @safe
    {
        // Note: Keep this in sync with `findUTXO`
        if (auto ptr = utxo in this.storage)
        {
            value = *ptr;
            return true;
        }
        return false;
    }

    ///
    protected override void remove (Hash utxo) @safe
    {
        this.storage.remove(utxo);
    }

    ///
    protected override void add (Hash utxo, UTXO value) @safe
    {
        this.storage[utxo] = value;
    }
}