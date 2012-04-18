
module luasp;
public import luad.all;
import std.file, std.datetime, std.stream, std.stdio : writefln;

enum LSP_WRITER    = "__luasp_writer";
enum LSP_USE_CACHE = "__luasp_usecache";

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

//class LSPException : Exception
//{
//    this() {}
//    this( const char[] msg )    { super( msg ); }
//    this( string msg )          { super( msg ); }
//}

// ------------------------------------------------------------------------- //
private immutable char chtype[ 256 ] =
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

LuaFunction loadLSPFile( LuaState L, const char[] filename )
{
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

    auto buf = cast(const(char)[]) std.file.read( filename );

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

    debug writefln( "=== PARSED ===\n%s ", outBuf.data );
    return L.loadString( outBuf.data );
}

// ------------------------------------------------------------------------- //

LuaObject[] doLSP( LuaState L, const char[] filename )
{
    if( !L.registry.get!bool( LSP_USE_CACHE ) )
    {
        auto f = loadLSPFile( L, filename );
        debug writefln( "Loaded LSP from %s: func = %s", filename, f.toString() );
        return f(); //execute it!
    }

    string cacheFile = std.path.setExtension( std.path.stripExtension( filename ), "luac" );

    if( exists( cacheFile ) )
    {
        SysTime atime1, mtime1, atime2, mtime2;
        getTimes( filename, atime1, mtime1 );
        getTimes( cacheFile, atime2, mtime2 );

        if( mtime1 < mtime2 ) //cache file is still relevant
        {
            //just execute the pre-compiled cached Lua code...
            return L.doFile( cacheFile );
        }
    }
    
    //we need to parse the file, dump the compiled code, and then execute it
    auto f = loadLSPFile( L, filename );
    if( f == f.init )
    {
        File cf = new File( cacheFile, FileMode.Out );
        scope(exit) cf.close();
        f.dump( (data) => cf.writeBlock( data.ptr, data.length ) == data.length );
    }

    return f();
}

// ------------------------------------------------------------------------- //

int lua_echo( LuaState L, LuaObject[] args )
{
    return 0;
}

// ------------------------------------------------------------------------- //

int lua_include( LuaState L, LuaObject[] args )
{
    return 0;
}

// ------------------------------------------------------------------------- //

int lua_print( LuaState L, LuaObject[] args )
{
    auto writer = L.registry.get!LuaObject( LSP_WRITER ); 

//    lua_getfield(L,LUA_REGISTRYINDEX,lsp_io_type);
//    lsp_io* io=(lsp_io*)lua_touserdata(L,-1);
    

    for( int i = 0; i < args.length; i++ )
    {
	    string s = args[ i ].toString();
//	    if( s is null )
//	        return luaL_error(L, LUA_QL("tostring") " must return a string to " LUA_QL("print"));
//
//
//        size_t ll = 0;
//        
//        while( ll < len )
//        {
//            size_t n=io->lwrite(io->lctx,s+ll,len-ll);
//            if(!n)
//            break;
//            ll+=n;
//        }
//
//        if(i<n)
//            io->lputc(io->lctx,'\t');
//
//        lua_pop(L,1);
    }

//    io->lputc(io->lctx,'\n');

    return 0;
}

// ------------------------------------------------------------------------- //

void openLSP( LuaState L )
{
    L[ "dotmpl" ]     = &lua_include;
    L[ "dofile_lsp" ] = &lua_include;
    L[ "echo" ]       = &lua_echo;
    L[ "write" ]      = &lua_echo;
    L[ "print" ]      = &lua_print;
   
    L.registry[ LSP_USE_CACHE ] = false;

    debug writefln( "Registered LSP handlers" );
//TODO    luaopen_lualspaux(L);
}

