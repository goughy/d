--
-- Monkey patch D language support into current premake (4.3, 4.4)
-- Note that this is a temporary solution until premake-dev is open
-- again for commits at which time D support should be mainline
--

io.write( "\nWARNING:\n\tLoading experimental D support as a monkey patch to premake 4.4\n" )
io.write( "\tThis patch provides addon support for the D programming language\n" )
io.write( "\tto the premake build configuration tool.  To do so, it must modify\n" )
io.write( "\tcore functions in premake that _may_ affect the correct operation of\n" )
io.write( "\tpremake.  This is no fault of premake.\n" )
io.write( "Written by Andrew Gough, 2011 http://bitbucket.org/goughy/premake-dev-d\n" )

local _G = _G;
local premake = _G.premake;
local table = _G.table;

module "d"

    local function table_print (tt, indent, done)
        done = done or {}
        indent = indent or 0
        if _G.type(tt) == "table" then
            for key, value in _G.pairs (tt) do
                _G.io.write(_G.string.rep (" ", indent)) -- indent it
                if _G.type (value) == "table" and not done [value] then
                    done [value] = true
                    _G.io.write(_G.string.format("[%s] => table\n", _G.tostring (key)));
                    _G.io.write(_G.string.rep (" ", indent+4)) -- indent it
                    _G.io.write("(\n");
                    table_print (value, indent + 7, done)
                    _G.io.write(_G.string.rep (" ", indent+4)) -- indent it
                    _G.io.write(")\n");
                else
                    _G.io.write(_G.string.format("[%s] => %s\n",
                    _G.tostring (key), _G.tostring(value)))
                end
            end
        else
            _G.io.write(tt .. "\n")
        end
    end 


-- do a mainline check - if D support exists, then the user shouldn't be
-- including our monkey patch extension
--
if premake.make.d ~= nil then
    _G.error( 'D support is already available - please remove d.lua' )
end

-- Configure/patch premake internals for D support
table.insert( premake.fields.language.allowed, "D" )
table.insert( premake.action.list.gmake.valid_languages, "D" )

-- Patch in valid D tools for the gmake action 
premake.action.list.gmake.valid_tools.dc = { "dmd", "gdc", "ldc" }

-- Override (well, replace, the gmake onproject() function to generate D stuff
local old_onproject = premake.action.list.gmake.onproject;
premake.action.list.gmake.onproject = function(prj)
	local makefile = _G._MAKE.getmakefilename(prj, true)
    if premake.isdproject(prj) then
        premake.generate(prj, makefile, premake.make_d)
    else
        old_onproject(prj)
    end
end
--table_print( premake, 0 );


-- 
-- Returns true if the solution contains at least one D project.
--

	function premake.hasdproject(sln)
		for prj in premake.solution.eachproject(sln) do
			if premake.isdproject(prj) then
				return true
			end
		end
	end

--
-- Returns true if the project uses the D language.
--

	function premake.isdproject(prj)
		return (prj.language == "D")
	end

	function _G.path.isdfile(fname)
		local extensions = { ".d", ".di" }
		local ext = _G.path.getextension(fname):lower()
		return table.contains(extensions, ext)
	end


--
-- This is a god awful hack! Its very fragile and modifies core functions in
-- premake - any upstream premake changes will be borked by this change!!!
--

    local old_gettool = premake.gettool
	function premake.gettool(cfg)
		if premake.isdproject(cfg) then
            if _G._OPTIONS.dc then
                return premake[ _G._OPTIONS.dc ]
            end
			if _G.action.valid_tools then
				return premake[_G.action.valid_tools.dc[1]]
			end
			return premake.dmd
		else
			return old_gettool(cfg)
		end
	end
	


--
-- dmd.lua
-- Provides GCC-specific configuration strings.
-- Copyright (c) 2002-2011 Jason Perkins and the Premake project
--

	
	premake.dmd = { }
	

--
-- Set default tools
--

	premake.dmd.dc    = "dmd"
	premake.dmd.ar    = "ar"
	
	
--
-- Translation of Premake flags into DMD flags
--

	local dmdflags =
	{
		ExtraWarnings  	= "-w",
		Optimize       	= "-O",
		Symbols        	= "-g",
		SymbolsLikeC   	= "-gc",
		Release		   	= "-release",
		Documentation  	= "-D",
		PIC			   	= "-fPIC",
		Inline		   	= "-inline",
		GenerateHeader	= "-H",
		GenerateMap		= "-map",
		NoBoundsCheck	= "-noboundscheck",
		NoFloat			= "-nofloat",
		RetainPaths		= "-op",
		Profile			= "-profile",
		Quiet			= "-quiet",
		Verbose         = "-v",
		Test		    = "-unittest",
		GenerateJSON	= "-X",
		CodeCoverage	= "-cov",
	}

	
	
--
-- Map platforms to flags
--

	premake.dmd.platforms = 
	{
		Native = {
			flags    = "",
			ldflags  = "", 
		},
		x32 = { 
			flags    = "-m32",
			ldflags  = " -L-L/usr/lib32", 
		},
		x64 = { 
			flags    = "-m64",
			ldflags  = "-L-L/usr/lib64",
		}
	}

	local platforms = premake.dmd.platforms


--
-- Returns the target name specific to compiler
--

    function premake.dmd.gettarget(name)
        return "-of" .. name
    end

--
-- Returns a list of compiler flags, based on the supplied configuration.
--

	function premake.dmd.getflags(cfg)
		local f = table.translate(cfg.flags, dmdflags)

		table.insert(f, platforms[cfg.platform].flags)

		--table.insert( f, "-v" )
		if cfg.kind == "StaticLib" then
			table.insert( f, "-lib" )
        elseif cfg.kind == "SharedLib" and cfg.system ~= "windows" then
			table.insert( f, "-fPIC" )
		end

        if premake.config.isdebugbuild( cfg ) then
			table.insert( f, "-debug" )
        else
			table.insert( f, "-release" )
        end
		return f
	end

--
-- Returns a list of linker flags, based on the supplied configuration.
--

	function premake.dmd.getldflags(cfg)
		local result = {}

		table.insert(result, platforms[cfg.platform].ldflags)

		for _, value in _G.ipairs(premake.getlinks(cfg, "all", "directory")) do
			table.insert(result, '-L-L' .. _G._MAKE.esc(value))
		end
		return result
	end

	function premake.dmd.getlinklibs(cfg)
		local result = {}
		for _, value in _G.ipairs(premake.getlinks(cfg, "dependencies", "fullpath")) do
				table.insert(result, _G._MAKE.esc(value))
		end
		for _, value in _G.ipairs(premake.getlinks(cfg, "system", "fullpath")) do
				table.insert(result, _G._MAKE.esc(value))
		end
		return result
	end

--
-- Decorate defines for the DMD command line.
--

	function premake.dmd.getdefines(defines)
		local result = { }
		for _,def in _G.ipairs(defines) do
        	table.insert(result, '-version=' .. def)
		end
		return result
	end


	
--
-- Decorate include file search paths for the DMD command line.
--

	function premake.dmd.getincludedirs(includedirs)
		local result = { }
		for _,dir in _G.ipairs(includedirs) do
			table.insert(result, "-I" .. _G._MAKE.esc(dir))
		end
		return result
	end



--
-- gdc.lua
-- Provides GDC-specific configuration strings.
-- Copyright (c) 2002-2011 Jason Perkins and the Premake project
--

	
	premake.gdc = { }
	

--
-- Set default tools
--

	premake.gdc.dc    = "gdc"
	

--
-- Translation of Premake flags into GDC flags
--

	local gdcflags =
	{
		ExtraWarnings  	= "-w",
		Optimize       	= "-O2",
		Symbols        	= "-g",
		SymbolsLikeC   	= "-fdebug-c",
        Deprecated      = "-fdeprecated",
		Release		   	= "-frelease",
		Documentation  	= "-fdoc",
		PIC			   	= "-fPIC",
		NoBoundsCheck	= "-fno-bounds-check",
		NoFloat			= "-nofloat",
		Test		    = "-funittest",
		GenerateJSON	= "-fXf",
        Verbose         = "-fd-verbose"
	}

	
	
--
-- Map platforms to flags
--

	premake.gdc.platforms = 
	{
		Native = {
			flags    = "",
			ldflags  = "", 
		},
		x32 = { 
			flags    = "-m32",
			ldflags  = " -L-L/usr/lib32", 
		},
		x64 = { 
			flags    = "-m64",
			ldflags  = "-L-L/usr/lib64",
		}
	}

	local platforms = premake.gdc.platforms
 
--
-- Returns the target name specific to compiler
--

    function premake.gdc.gettarget(name)
        return "-o " .. name
    end

--
-- Returns a list of compiler flags, based on the supplied configuration.
--

	function premake.gdc.getflags(cfg)
		local f = table.translate(cfg.flags, gdcflags)

		table.insert(f, platforms[cfg.platform].flags)

		--table.insert( f, "-v" )
		if cfg.kind == "StaticLib" then
			table.insert( f, "-static" )
        elseif cfg.kind == "SharedLib" and cfg.system ~= "windows" then
			table.insert( f, "-fPIC -shared" )
		end

        if premake.config.isdebugbuild( cfg ) then
			table.insert( f, "-fdebug" )
        else
			table.insert( f, "-frelease" )
        end
		return f
	end

--
-- Returns a list of linker flags, based on the supplied configuration.
--

	function premake.gdc.getldflags(cfg)
		local result = {}

		table.insert(result, platforms[cfg.platform].ldflags)

		for _, value in _G.ipairs(premake.getlinks(cfg, "all", "directory")) do
			table.insert(result, '-L-L' .. _G._MAKE.esc(value))
		end
		return result
	end

	function premake.gdc.getlinklibs(cfg)
		local result = {}
		for _, value in _G.ipairs(premake.getlinks(cfg, "system", "fullpath")) do
				table.insert(result, _G._MAKE.esc(value))
		end
		return result
	end

--
-- Decorate defines for the gdc command line.
--

	function premake.gdc.getdefines(defines)
		local result = { }
		for _,def in _G.ipairs(defines) do
        	table.insert(result, '-fversion=' .. def)
		end
		return result
	end


	
--
-- Decorate include file search paths for the gdc command line.
--

	function premake.gdc.getincludedirs(includedirs)
		local result = { }
		for _,dir in _G.ipairs(includedirs) do
			table.insert(result, "-I" .. _G._MAKE.esc(dir))
		end
		return result
	end



--
-- ldc.lua
-- Provides LDC-specific configuration strings.
-- Copyright (c) 2002-2011 Jason Perkins and the Premake project
--

	
	premake.ldc = { }
	

--
-- Set default tools
--

	premake.ldc.dc    = "ldc2"
	
	
--
-- Translation of Premake flags into GCC flags
--

	local ldcflags =
	{
		ExtraWarnings  	= "-w",
		Optimize       	= "-O2",
		Symbols        	= "-g",
		SymbolsLikeC   	= "-gc",
		Release		   	= "-release",
		Documentation  	= "-D",
		GenerateHeader	= "-H",
		RetainPaths		= "-op",
		Verbose         = "-v",
		Test		    = "-unittest",
	}

	
	
--
-- Map platforms to flags
--

	premake.ldc.platforms = 
	{
		Native = {
			flags    = "",
			ldflags  = "", 
		},
		x32 = { 
			flags    = "-m32",
			ldflags  = " -L-L/usr/lib32", 
		},
		x64 = { 
			flags    = "-m64",
			ldflags  = "-L-L/usr/lib64",
		}
	}

	local platforms = premake.ldc.platforms


--
-- Returns the target name specific to compiler
--

    function premake.ldc.gettarget(name)
        return "-of=" .. name
    end

--
-- Returns a list of compiler flags, based on the supplied configuration.
--

	function premake.ldc.getflags(cfg)
		local f = table.translate(cfg.flags, ldcflags)

		table.insert(f, platforms[cfg.platform].flags)

		--table.insert( f, "-v" )
		if cfg.kind == "StaticLib" then
			table.insert( f, "-lib" )
        elseif cfg.kind == "SharedLib" and cfg.system ~= "windows" then
			table.insert( f, "-relocation-model=pic" )
		end

        if premake.config.isdebugbuild( cfg ) then
			table.insert( f, "-d-debug" )
        else
			table.insert( f, "-release" )
        end
		return f
	end

--
-- Returns a list of linker flags, based on the supplied configuration.
--

	function premake.ldc.getldflags(cfg)
		local result = {}

		table.insert(result, platforms[cfg.platform].ldflags)

		for _, value in _G.ipairs(premake.getlinks(cfg, "all", "directory")) do
			table.insert(result, '-L-L' .. _G._MAKE.esc(value))
		end
		return result
	end

	function premake.ldc.getlinklibs(cfg)
		local result = {}
		for _, value in _G.ipairs(premake.getlinks(cfg, "system", "fullpath")) do
				table.insert(result, _G._MAKE.esc(value))
		end
		return result
	end

--
-- Decorate defines for the ldc command line.
--

	function premake.ldc.getdefines(defines)
		local result = { }
		for _,def in _G.ipairs(defines) do
        	table.insert(result, '-d-version=' .. def)
		end
		return result
	end


	
--
-- Decorate include file search paths for the ldc command line.
--

	function premake.ldc.getincludedirs(includedirs)
		local result = { }
		for _,dir in _G.ipairs(includedirs) do
			table.insert(result, "-I=" .. _G._MAKE.esc(dir))
		end
		return result
	end


--
-- make_d.lua
-- Generate a D project makefile.
--

	premake.make.d = { }
	local _ = premake.make.d
	

	function premake.make_d(prj)

		-- create a shortcut to the compiler interface
		local dc = premake.gettool(prj)
		
		-- build a list of supported target platforms that also includes a generic build
		local platforms = premake.filterplatforms(prj.solution, dc.platforms, "Native")
		
		premake.gmake_d_header(prj, dc, platforms)

		for _, platform in _G.ipairs(platforms) do
			for cfg in premake.eachconfig(prj, platform) do
				premake.gmake_d_config(cfg, dc)
			end
		end
		
		-- list intermediate files
		_G._p('D_FILES := \\')
		for _, file in _G.ipairs(prj.files) do
			if _G.path.isdfile(file) then
				_G._p('\t%s \\', _G._MAKE.esc(file))
			end
		end
		_G._p('')
 
		-- main build rule(s)
		_G._p('.PHONY: clean prebuild prelink')
		_G._p('')

		_G._p('all: $(TARGETDIR) $(OBJDIR) prebuild prelink $(TARGET)')
		_G._p('\t@:')
		_G._p('')

		
		_G._p('$(TARGET): $(D_FILES)')
		_G._p('\t@echo Building %s', prj.name)
		_G._p('\t$(SILENT) $(DC) $(DFLAGS) $(LDFLAGS) ' .. dc.gettarget("$@") .. ' $(D_FILES) $(LIBS)')
		_G._p('\t$(POSTBUILDCMDS)')
		_G._p('')
		
		-- Create destination directories. Can't use $@ for this because it loses the
		-- escaping, causing issues with spaces and parenthesis
		_G._p('$(TARGETDIR):')
		premake.make_mkdirrule("$(TARGETDIR)")
		
		_G._p('$(OBJDIR):')
		premake.make_mkdirrule("$(OBJDIR)")

		-- clean target
		_G._p('clean:')
		_G._p('\t@echo Cleaning %s', prj.name)
		_G._p('ifeq (posix,$(SHELLTYPE))')
		_G._p('\t$(SILENT) rm -f  $(TARGET)')
		_G._p('\t$(SILENT) rm -rf $(OBJDIR)')
		_G._p('else')
		_G._p('\t$(SILENT) if exist $(subst /,\\\\,$(TARGET)) del $(subst /,\\\\,$(TARGET))')
		_G._p('\t$(SILENT) if exist $(subst /,\\\\,$(OBJDIR)) rmdir /s /q $(subst /,\\\\,$(OBJDIR))')
		_G._p('endif')
		_G._p('')

		-- custom build step targets
		_G._p('prebuild:')
		_G._p('\t$(PREBUILDCMDS)')
		_G._p('')
		
		_G._p('prelink:')
		_G._p('\t$(PRELINKCMDS)')
		_G._p('')

		-- include the dependencies, built by DMD (with the -MMD flag)
		--_G._p('-include $(OBJECTS:%%.o=%%.d)')
	end



--
-- Write the makefile header
--

	function premake.gmake_d_header(prj, dc, platforms)
		_G._p('# %s project makefile autogenerated by Premake', premake.action.current().shortname)

		-- set up the environment
		_G._p('ifndef config')
		_G._p('  config=%s', _G._MAKE.esc(premake.getconfigname(prj.solution.configurations[1], platforms[1], true)))
		_G._p('endif')
		_G._p('')
		
		_G._p('ifndef verbose')
		_G._p('  SILENT = @')
		_G._p('endif')
		_G._p('')
	
		_G._p('ifndef DC')
		_G._p('  DC = %s', dc.dc)
		_G._p('endif')
		_G._p('')

		-- identify the shell type
		_G._p('SHELLTYPE := msdos')
		_G._p('ifeq (,$(ComSpec)$(COMSPEC))')
		_G._p('  SHELLTYPE := posix')
		_G._p('endif')
		_G._p('ifeq (/bin,$(findstring /bin,$(SHELL)))')
		_G._p('  SHELLTYPE := posix')
		_G._p('endif')
		_G._p('')
		
	end
	
	
--
-- Write a block of configuration settings.
--

	function premake.gmake_d_config(cfg, dc)

       --table_print( cfg, 0, false )

		_G._p('ifeq ($(config),%s)', _G._MAKE.esc(cfg.shortname))
		
		-- if this platform requires a special compiler or linker, list it now
		local platform = dc.platforms[cfg.platform]
		if platform.dc then
			_G._p('  DC         = %s', platform.dc)
		end

		_G._p('  OBJDIR     = %s', _G._MAKE.esc(cfg.objectsdir))		
		_G._p('  TARGETDIR  = %s', _G._MAKE.esc(cfg.buildtarget.directory))
		_G._p('  TARGET     = $(TARGETDIR)/%s', _G._MAKE.esc(cfg.buildtarget.name))
		_G._p('  DEFINES   += %s', table.concat(dc.getdefines(cfg.defines), " "))
		_G._p('  INCLUDES  += %s', table.concat(dc.getincludedirs(cfg.includedirs), " "))
		_G._p('  DFLAGS    += %s $(DEFINES) $(INCLUDES)', table.concat(table.join(dc.getflags(cfg), cfg.buildoptions), " "))
		_G._p('  LDFLAGS   += %s', table.concat(table.join(dc.getldflags(cfg), cfg.linkoptions), " "))
		_G._p('  LIBS      += %s', table.concat(dc.getlinklibs(cfg), " "))
		_G._p('')
		_G._p('  define PREBUILDCMDS')
		if #cfg.prebuildcommands > 0 then
			_G._p('\t@echo Running pre-build commands')
			_G._p('\t%s', table.implode(cfg.prebuildcommands, "", "", "\n\t"))
		end
		_G._p('  endef')

		_G._p('  define PRELINKCMDS')
		if #cfg.prelinkcommands > 0 then
			_G._p('\t@echo Running pre-link commands')
			_G._p('\t%s', table.implode(cfg.prelinkcommands, "", "", "\n\t"))
		end
		_G._p('  endef')

		_G._p('  define POSTBUILDCMDS')
		if #cfg.postbuildcommands > 0 then
			_G._p('\t@echo Running post-build commands')
			_G._p('\t%s', table.implode(cfg.postbuildcommands, "", "", "\n\t"))
		end
		_G._p('  endef')
		
		_G._p('endif')
		_G._p('')
	end
	

--
-- Set up the DC command line option...
--

	_G.newoption
	{
		trigger     = "dc",
		value       = "VALUE",
		description = "Choose a D compiler set",
		allowed = {
			{ "dmd",   "Digital Mars DMD (default)" },
			{ "gdc",   "GNU GDC (gdc)"    },
			{ "ldc",   "LLVM LDC (ldc2)"  },
		}
	}

