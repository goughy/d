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
    string base = "http://localhost:8000";
    if( args.length > 1 )
        base = args[ 1 ];

    int num = 1000;
    if( args.length > 2 )
        num = to!int( args[ 2 ] );

    writeln( "Connecting to URL " ~ base );
    for( int i = 0; i < num; ++i )
    {
        if( i % 2 == 0 )
            httpClient( base ~ "/v1/test" );
        else
            httpClient( base ~ "/v1/account" );
    }
    writeln( "Bye" );
    return 0;
}

// ------------------------------------------------------------------------- //


