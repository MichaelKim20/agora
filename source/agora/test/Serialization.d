module agora.test.Serialization;

version (unittest):
import agora.crypto.Types;
import agora.utils.Test;
import agora.consensus.data.Params;
import agora.consensus.data.Transaction;
import agora.consensus.data.Block;
import vibe.data.json;
import agora.serialization.Serializer;
import agora.test.Base;

import core.thread;
import std.stdio;

public string toHexString(ref ubyte[] data)
{
    static immutable LHexDigits = `0123456789abcdef`;
    string str = "";
    char[2] hex;
    for (int i; i < data.length; i++)
    {
        hex[0] = LHexDigits[data[i] >> 4];
        hex[1] = LHexDigits[(data[i] & 0b0000_1111)];
        str ~= hex;
    }
    return str;
}

unittest
{
    const TestConf conf = { recurring_enrollment : false };
    auto network = makeTestNetwork!TestAPIManager(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    auto nodes = network.clients;
    auto node_1 = nodes[0];

    auto gen_key_pair = WK.Keys.Genesis;
    // Get the genesis block, make sure it's the only block externalized
    auto blocks = node_1.getBlocksFrom(0, 2);
    assert(blocks.length == 1, "Should only have Genesis Block at this time");

    writefln("%s", blocks[0].serializeToJsonString());

    ubyte[] buffer;

    serializeToBuffer(blocks[0].txs[0], buffer);
    writefln("serialized data of txs[0] : %s", toHexString(buffer));

    serializeToBuffer(blocks[0].header.enrollments[0], buffer);
    writefln("serialized data of enrollment[0] : %s", toHexString(buffer));

    serializeToBuffer(blocks[0].header.validators, buffer);
    writefln("serialized data of validators : %s", toHexString(buffer));

    serializeToBuffer(blocks[0].header, buffer);
    writefln("serialized data of header : %s", toHexString(buffer));

    serializeToBuffer(blocks[0], buffer);
    writefln("serialized data of block : %s", toHexString(buffer));
}
