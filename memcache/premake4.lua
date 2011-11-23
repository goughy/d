
solution "dmemcache"
	configurations { "debug" }

    configuration { "debug", "gmake" }
        buildoptions { "-gc" }

	project "test"
		kind "ConsoleApp"
		language "D"
		files { "memcache.d", "test.d" }

		configuration "debug"
			defines "debug"
            platforms "x64"
			flags { "Symbols", "ExtraWarnings", "Test" }

