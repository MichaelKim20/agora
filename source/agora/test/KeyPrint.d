module agora.test.KeyPrint;

version (unittest):
import agora.crypto.Types;
import agora.utils.Test;
import std.stdio;
/*
unittest
{
        writeln("%s", WK.Keys.NODE2.address.toString());
        writeln("%s", WK.Keys.NODE2.secret.toString(PrintMode.Clear));
        writeln("");

        writeln("%s", WK.Keys.NODE3.address.toString());
        writeln("%s", WK.Keys.NODE3.secret.toString(PrintMode.Clear));
        writeln("");

        writeln("%s", WK.Keys.NODE4.address.toString());
        writeln("%s", WK.Keys.NODE4.secret.toString(PrintMode.Clear));
        writeln("");

        writeln("%s", WK.Keys.NODE5.address.toString());
        writeln("%s", WK.Keys.NODE5.secret.toString(PrintMode.Clear));
        writeln("");

        writeln("%s", WK.Keys.NODE6.address.toString());
        writeln("%s", WK.Keys.NODE6.secret.toString(PrintMode.Clear));
        writeln("");

        writeln("%s", WK.Keys.NODE7.address.toString());
        writeln("%s", WK.Keys.NODE7.secret.toString(PrintMode.Clear));
        writeln("");

    for (int index = 0; index <= 1377; index++)
    {
        writefln("%s", agora.utils.Test.WK.Keys[index].address.toString());
        writefln("%s", agora.utils.Test.WK.Keys[index].secret.toString(PrintMode.Clear));
        writeln("");
    }
}
*/

unittest
{
    writefln("%s", WK.Keys.Genesis.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.CommonsBudget.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE2.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE3.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE4.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE5.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE6.secret.toString(PrintMode.Clear));
    writefln("%s", WK.Keys.NODE7.secret.toString(PrintMode.Clear));
    writefln("");

    for (int index = 0; index <= 1377; index++)
    {
        writefln("%s", agora.utils.Test.WK.Keys[index].secret.toString(PrintMode.Clear));
    }
}

