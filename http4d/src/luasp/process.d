
module luasp.process;

public import luad.all;
import luad.stack, luad.error, luad.c.all;
import std.file, std.datetime, std.stream, std.stdio, std.conv;

// ------------------------------------------------------------------------- //
// ------------------------------------------------------------------------- //

interface LspCallback
{
    void writer( in string content );
    void log( lazy string msg );
    string[] getHeader( in string name );
    void setHeader( in string name, in string value );
    void error( in string msg );
}

// ------------------------------------------------------------------------- //
// ------------------------------------------------------------------------- //

LuaTable funcEnv;

void luaPanic( LuaState L , const(char[]) msg )
{
    writefln( "LUA:PANIC:%s", msg );
    throw new LuaErrorException( msg.idup );
}

// ------------------------------------------------------------------------- //

class LspState
{
    this( LspCallback cb, bool cache = false )
    {
        L   = new LuaState;
//        L.setPanicHandler( &luaPanic );
        L.openLibs();

        cb_ = cb;
        cache_ = cache;
    }

    ~this()
    {
        env_.release();
    }

    void process( string filename )
    {
        doLsp( filename );
    }

    void doLsp( string filename )
    {
        if( funcEnv.isNil ) 
        {
            //first time in this thread processing, so configure the per-thread
            //function environment
            funcEnv = L.newTable();

            //populate the new environment with the full global env also: see http://www.lua.org/pil/14.3.html
            auto meta = L.newTable();
            meta[ "__index" ] = L.globals;
            funcEnv.setMetaTable( meta );

            funcEnv[ "dotmpl" ]         = &lsp_include;
            funcEnv[ "dofile_lsp" ]     = &lsp_include;
            funcEnv[ "echo" ]           = &lsp_echo;
            funcEnv[ "write" ]          = &lsp_echo;
            funcEnv[ "print" ]          = &lsp_print;
            funcEnv[ "log" ]            = &lsp_log;

            funcEnv[ "url_decode" ]     = &lsp_url_decode;
            funcEnv[ "args_decode" ]    = &lsp_args_decode;
            funcEnv[ "content_type" ]   = &lsp_content_type;
            funcEnv[ "set_out_header" ] = &lsp_set_out_header;
            funcEnv[ "get_in_header" ]  = &lsp_get_in_header;
            funcEnv[ "uuid_gen" ]       = &lsp_uuid_gen;
        }

        funcEnv[ "env" ]  = env();
        funcEnv[ "args" ] = env[ "args" ];

        debug writefln( "LSP: executing %s", filename );
        lsp_include( filename );
    }

    @property LuaState state() { return L; }

    @property LuaTable env()
    {
        if( env_.isNil )
            env_ = L.newTable();

        return env_;
    }

    @property bool cache()          { return cache_; }
    @property void cache( bool c )  { cache_ = c;    }

    @property LspCallback callback() { return cb_; }

    // ------------------------------------------------------------------------- //

    string lsp_uuid_gen()
    {
        static immutable char hex[ 16 ] = 
            [ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' ];

        enum GUID_LEN = 16;

        version(Posix)
        {
            auto bytes = cast(char[]) std.file.read( "/dev/urandom", GUID_LEN );
            auto guid = std.array.appender!(char[])();
            guid.reserve( GUID_LEN * 2 );
            for( int i = 0; i < bytes.length; )
            {
                guid.put( hex[ bytes[ i ] / 16 ] );
                guid.put( hex[ bytes[ i++ ] % 16 ] );
            }
            return guid.data.idup;
        }
    }

    // ------------------------------------------------------------------------- //

private:

    LuaState  L;
    LuaTable  env_;
    LspCallback cb_;
    bool      cache_;

    // ------------------------------------------------------------------------- //

    void lsp_include( in string filename )
    {
        auto f = loadLsp( filename );
        f.setEnvironment( funcEnv );
        try
        {
            f.call();
        }
        catch( LuaErrorException e )
        {
            cb_.error( e.toString() );
        }
    }

    // ------------------------------------------------------------------------- //

    void lsp_echo( LuaObject[] params... )
    {
        if( params.length > 0 )
        {
            foreach( param; params[ 0 .. $-1 ] )
            {
                cb_.writer( param.toString );
                cb_.writer( " " );
            }
            cb_.writer( params[ $-1 ].toString );
        }
    }

    // ------------------------------------------------------------------------- //

    void lsp_print( LuaObject[] params... )
    {
        if( params.length > 0 )
        {
            foreach( param; params[ 0 .. $ - 1 ] )
            {
                cb_.writer( param.toString );
                cb_.writer( "\t" );
            }
            cb_.writer( params[ $ - 1 ].toString );
        }
        cb_.writer( "\n" );
    }

    // ------------------------------------------------------------------------- //

    string lsp_url_decode( string url )
    {
        return decodeUrl( url );
    }

    // ------------------------------------------------------------------------- //

    LuaTable lsp_args_decode( string args )
    {
        //locate each k=v pair between '&' characters
        //and push them to a new table...
        auto result = L.newTable();
        auto vals   = std.algorithm.splitter( args, "&" );
        foreach( v; vals )
        {
            auto kv = std.algorithm.findSplit( v, "=" );
            result[ kv[ 0 ] ] = decodeUrl( kv[ 2 ] );
        }

        return result;
    }

    // ------------------------------------------------------------------------- //

    void lsp_log( string msg )
    {
        cb_.log( msg );
    }

    // ------------------------------------------------------------------------- //

    void lsp_content_type( string type )
    {
        lsp_set_out_header( "Content-Type", type );
    }

    // ------------------------------------------------------------------------- //

    void lsp_set_out_header( string key, string value )
    {
        cb_.setHeader( key, value );
    }

    // ------------------------------------------------------------------------- //

    string lsp_get_in_header( string key )
    {
        return cb_.getHeader( key )[ 0 ];
    }

    // ------------------------------------------------------------------------- //

    LuaFunction loadLsp( string filename )
    {
        LuaFunction func;

        if( !cache_ )
            func = parseLsp( filename );
        else
        {
            string cacheFile = std.path.setExtension( std.path.stripExtension( filename ), "luac" );

            if( exists( cacheFile ) )
            {
                SysTime atime1, mtime1, atime2, mtime2;
                getTimes( filename, atime1, mtime1 );
                getTimes( cacheFile, atime2, mtime2 );

                if( mtime1 < mtime2 ) //cache file is still relevant
                    func = L.loadFile( cacheFile );
            }

            if( func.isNil )
            {
                //we need to parse the file, dump the compiled code, and then execute it
                func = parseLsp( filename );
                if( !func.isNil )
                {
                    std.stream.File cf = new std.stream.File( cacheFile, std.stream.FileMode.Out );
                    scope(exit) cf.close();
                    func.dump( (data) => cf.writeBlock( data.ptr, data.length ) == data.length );
                }
            }
        }

        debug writefln( "LSP: loaded %s", filename );
        return func;
    }

    // ------------------------------------------------------------------------- //

    LuaFunction parseLsp( string filename )
    {
        return L.loadString( parseLspFile( filename ) );
    }

}

// ------------------------------------------------------------------------- //

scope struct ChDir
{
    this( const char[] path )
    {
        cwd = getcwd();
        chdir( path );
    }

    ~this()
    {
        if( cwd !is null )
            chdir( cwd );
    }

private:

    string cwd;
}

// ------------------------------------------------------------------------- //

const(char[]) parseLspFile( string filename )
{
    immutable char chtype[ 256 ] =
    [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x61, 0x62, 0x74, 0x6e, 0x76, 0x66, 0x72, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5c, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ];

    enum Status 
    {
        echo1,
        echo2,
        echo3,
        echo4,
        stmt1,
        stmt12,
        stmt13,
        stmt2,
        stmt3,
        comment1,
        comment2,
        cr1,
        cr2,
    }

    auto outBuf = std.array.appender!(char[])();
    void putc( char c )
    {
        char ct = chtype[ c ];
        switch( ct )
        {
            case 0x00: 
                outBuf.put( c ); 
                break;

            case 0xff: 
                outBuf.put( '.' ); 
                break;

            default: 
                outBuf.put( '\\' ); 
                outBuf.put( ct ); 
                break;
        }
    }

    auto buf = cast(const(char[])) std.file.read( filename );

    uint currLine;
    outBuf.reserve( cast(ulong) (buf.length * 1.5) );

    Status st = Status.echo1;
    for( int i = 0; i < buf.length; ++i )
    {
        char ch = buf[ i ];
        if( ch == '\n' )
            currLine++;

        switch( st )
        {
            case Status.echo1:
                if( ch == '<' )
                    st = Status.echo4;
                else
                {
                    outBuf.put( "\necho('" ); //NB includes open quote
                    putc( ch );
                    st = Status.echo2;
                }
                break;
                       
            case Status.echo2:
	            if( ch == '<' )
		            st = Status.echo3;
	            else
                    putc( ch );
                break;

            case Status.echo3:
                if( ch == '?' )
                {
                    outBuf.put( "'); " );
                    st = Status.stmt1;
                }
                else
                {
                    outBuf.put( '<' );
                    putc( ch );
                    st = Status.echo2;
                }
                break;

            case Status.echo4:
                if( ch == '?' )
                    st = Status.stmt1;
                else
                {
                    outBuf.put( "\necho('<" );
                    putc( ch );
                    st = Status.echo2;
                }
                break;

            case Status.stmt1:
                if( ch == '=' )
                {
                    outBuf.put( "\necho(" ); //NB: no open quote
                    st = Status.stmt2;
                }
                else if( ch == '#' )
                    st = Status.comment1;
                else
                {
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt12;
                }
                break;

            case Status.stmt2:
                if( ch == '?' )
                    st = Status.stmt3;
                else
                    outBuf.put( ch ); //NB: no escaping
                break;

            case Status.stmt3:
                if( ch == '>' )
                {
                    outBuf.put( "); " );
                    st = Status.cr1;
                }
                else if( ch == '?' )
                    outBuf.put( '?' );
                else
                {
                    outBuf.put( '?' );
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt2;
                }
                break;

            case Status.stmt12:
                if( ch == '?' )
                    st = Status.stmt13;
                else
                    outBuf.put( ch ); //NB: no escaping
                break;

            case Status.stmt13:
                if( ch == '>' )
                {
                    outBuf.put( ' ' );
                    st = Status.cr1;
                }
                else if( ch == '?' )
                    outBuf.put( '?' );
                else
                {
                    outBuf.put( '?' );
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt12;
                }
                break;

            case Status.comment1:
                if( ch == '?' )
                    st = Status.comment2;
                break;

            case Status.comment2:
                if( ch == '>' )
                    st = Status.cr1;
                else if( ch != '?' )
                    st = Status.comment1;
                break;

            case Status.cr1:
                if( ch == '\r' )
                    st = Status.cr2;
                else
                {
                    if( ch != '\n' )
                        i--;

                    st = Status.echo1;
                }
                break;

            case Status.cr2:
                if( ch != '\n' )
                    i--;
                else
                    st = Status.echo1;
                break;

            default: 
                break;
        }

//        debug if( outBuf.data.length > 0 ) writefln( "In %x, last %x", ch, outBuf.data[ $ - 1 ] );
    }

    switch( st )
    {
        case Status.echo1:
        case Status.cr1:
        case Status.cr2:
            break;

        case Status.echo2:
            outBuf.put( "') " );
            break;

        default:
            //TODO: luaL_lsp_error(L); - what do we do in LuaD??
            break;
    }

    outBuf.put( '\n' );

//    debug writefln( "=== PARSED ===\n%s\n======", outBuf.data );
    return outBuf.data;
}

// ------------------------------------------------------------------------- //

string decodeUrl( string url )
{
    static immutable char hex[256] =
    [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    ];

    auto buf = std.array.appender!(char[])();

    for( int i = 0; i < url.length; i++ )
    {
        immutable char c = url[ i ];
        switch( c )
        {
            case '+': 
                buf.put( ' ' ); 
                break;

            case '%':
                if( url.length >= i + 2 )
                {
                    immutable c1 = hex[ url[ ++i ] ];
                    immutable c2 = hex[ url[ ++i ] ];

                    if( c1 != 0xff && c2 != 0xff )
                        buf.put( cast(char) (((c1 << 4) & 0xf0) | (c2 & 0x0f)) );
                    else
                        buf.put( '.' );
                }
                break;

            default: 
                buf.put( c );
                break;
        }	
    }
    
    return buf.data.idup;
}

// ------------------------------------------------------------------------- //

debug void onPanic( LuaState L, in char[] msg )
{
    writefln( "PANIC: %s", msg );
}

unittest 
{
    class CB : LspCallback
    {
        void writer( in string content ) { write( content ); }
        void log( in string msg ) { writeln( "LOG: %s", msg ); }
        string getHeader( in string name ) { return ""; }
        void setHeader( in string name, in string value ) {  } 
        void error( in string msg ) { writeln( "ERR: %s", msg ); }
    }
    writeln( "Unit test executing" );

    LuaState L = new LuaState;
    L.openLibs();
    L.setPanicHandler( &onPanic );

    LspState lsp = new LspState( L, new CB );
    assert( lsp.lsp_uuid_gen().length == 32 );
    writeln( "UUID: ", lsp.lsp_uuid_gen() );

    //test URL decode
    assert( lsp.lsp_url_decode( "abc+def" ) == "abc def" );
    assert( lsp.lsp_url_decode( "abc%2C+def" ) == "abc, def" );
    assert( lsp.lsp_url_decode( "http://www.permadi.com/tutorial/urlEncoding/example.html?var=This+is+a+simple+%26+short+test." ) == "http://www.permadi.com/tutorial/urlEncoding/example.html?var=This is a simple & short test." );

    auto res = lsp.lsp_args_decode( "abc=def&ghi=two+two%2C" );
//    assert( res.length == 2 );
    foreach( string k, string v; res )
    {
        debug writeln( k, " = ", v );
        if( k == "abc" ) assert( v == "def" );
        if( k == "ghi" ) assert( v == "two two," );
    }

    writeln( "Unit test finished" );
}
