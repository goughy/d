
module util.util;

import std.stdio, std.string;
import std.ascii : isPrintable;
import std.array : replicate;

// ------------------------------------------------------------------------- //

void dumpHex( char[] buf, string title = "", int cols = 16 )
{
    assert( cols < 256 );

    if( title.length > 0 )
        writeln( title );

    char[ 256 ] b1;
    int x = 0, i = 0;
    for(; i < buf.length; ++i )
    {
        if( x > 0 && i > 0 && i % cols == 0 )
        {
            writefln( "   %s", b1[ 0 .. x ] );
            x = 0;
        }
        b1[ x++ ] = .isPrintable( buf[ i ] ) ? buf[ i ] : '.';
        writef( "%02x ", buf[ i ] );
    }
//		writefln( "\n(D) x = %d, i = %d", x, i );
    if( x > 0 )
        writefln( "%s   %s", ( cols > x ) ? replicate( "   ", cols - x ) : "", b1[ 0 .. x ] );
}

// ------------------------------------------------------------------------- //

/**
 * Generate a get/set member property stanza for class boilerplate simplification
 */

string PropertyRO( T ) ( string propName )
{
    return "@property " ~ T.stringof ~ " " ~ propName ~ "() { return _" ~ propName ~ "; }";
}

string PropertyRW( T ) ( string propName )
{
    return "@property " ~ T.stringof ~ " " ~ propName ~ "() { return _" ~ propName ~ "; } \n"
           ~ "@property " ~ T.stringof ~ " " ~ propName ~ "(" ~ T.stringof ~ " p) { _"
           ~ propName ~ " = p; return _" ~ propName ~ "; } ";
}

// ------------------------------------------------------------------------- //


