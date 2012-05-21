
import std.stdio, std.datetime;
import luasp.all;

int main( string [] args )
{
    if( args.length < 2 )
    {
        writefln( "Usage: %s [directory of LSP files]", args[ 0 ] );
        return 1;
    }

    luaspServe( args[ 1 ] );
    return 0;
}

