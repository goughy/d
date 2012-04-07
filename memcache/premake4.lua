
solution "memcached"
	configurations { "debug" }

    configuration { "debug", "gmake" }
        buildoptions { "-gc" }

    project "memcached"
        kind "StaticLib"
        language "D"
		files { "memcache.d" }
		flags { "Symbols", "ExtraWarnings" }

	project "test"
		kind "ConsoleApp"
		language "D"
		files { "test.d" }
        links { "libmemcached.a" }
		flags { "Symbols", "ExtraWarnings" }

