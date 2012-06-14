
import std.stdio, std.datetime;
import protocol.http, protocol.mongrel2, luasp.all;

int main( string [] args )
{
    if( args.length < 2 )
    {
        writefln( "Usage: %s [directory of LSP files]", args[ 0 ] );
        return 1;
    }

    LSPDispatch dispatcher = new LSPDispatch( args[ 1 ] );

    httpServe( "127.0.0.1:8081", (req) => dispatcher( req ) );
//    mongrel2Serve( "127.0.0.1", 8081, (req) => dispatcher( req ) );
//    luaspServe( args[ 1 ], "0.0.0.0", 8081 );
    return 0;
}

