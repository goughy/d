import std.stdio, std.string, std.regex, std.range, std.conv, std.math, std.stdint;
import std.getopt;
import std.file, std.path, std.socket, std.concurrency;

import protocol.http;

auto debugLvl = 0;
auto quiet    = false;

// ------------------------------------------------------------------------- //

void msg( T ... ) ( int i, T opts )
{
    if( !quiet && i <= debugLvl )
    {
        writeln( "(I) ", opts );
    }
}

// ------------------------------------------------------------------------- //

void usage( string name )
{
    writeln();
    writeln( "Usage: ", name, " [options]" );
    writeln( "where [options] are:" );
    writeln();
    writeln( "\t--debug|-d lvl\t\tSet debug level to 'lvl'" );
    writeln( "\t--port|-p [n]\t\tAccept incoming connections on port [n]" );
    writeln( "\t\t\t\tDisplay this help message" );
}

// ------------------------------------------------------------------------- //

int main( string[] args )
{
    if( args.length < 2 )
    {
        usage( args[ 0 ] );
        return 1;
    }

    Uri u = Uri( args[ 1 ] );

    HttpRequest req = new HttpRequest;
    req.method   = Method.GET;
    req.protocol = HTTP_11; //auto-close
    req.uri      = u.path;

    req.headers[ "Host" ]   ~= u.host ~ ":" ~ to!string( u.port );
    req.headers[ "Accept" ] ~= "*";

    writeln( "Connecting to URL " ~ u.toString() );
    auto resp = httpClient( req );
    debug dump( resp );
    return 0;
}

// ------------------------------------------------------------------------- //


