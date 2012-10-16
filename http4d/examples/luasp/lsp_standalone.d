
import std.stdio, luasp.process;

int main( string [] args )
{
    LspState state = new LspState( new class LspCallback 
    {
        void writer( in string content )                    { write( content );           }
        void log( lazy string msg )                         { writefln( "LOG: %s", msg ); }
        void error( in string msg )                         { writefln( "\nERR: %s", msg );       }
        string getHeader( in string name )                  { return "";                  }
        void setHeader( in string name, in string value )   { /*ignored*/                 }
    } );

    state.process( args[ 1 ] );
    return 0;
}
