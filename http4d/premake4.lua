
solution "http4d"
	configurations { "debug" }

    configuration { "debug", "gmake" }
        buildoptions { "-gc" }

	project "http4d"
		kind "StaticLib"
		language "D"
		files { "**.d" }
		excludes { "main.d" }

		configuration "debug64"
			defines { "debug" }
            platforms "x64"
			flags { "Symbols", "ExtraWarnings" }

	project "test"
		kind "ConsoleApp"
		language "D"
		files { "main.d" }
		links { "libhttp4d.a" }

		configuration "debug64"
			defines "debug"
            platforms "x64"
			flags { "Symbols", "ExtraWarnings", "Test" }

