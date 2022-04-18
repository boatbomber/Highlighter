local language = {
	keyword = {
		["and"] = true,
		["break"] = true,
		["continue"] = true,
		["do"] = true,
		["else"] = true,
		["elseif"] = true,
		["end"] = true,
		["export"] = true,
		["false"] = true,
		["for"] = true,
		["function"] = true,
		["if"] = true,
		["in"] = true,
		["local"] = true,
		["nil"] = true,
		["not"] = true,
		["or"] = true,
		["repeat"] = true,
		["return"] = true,
		["self"] = true,
		["then"] = true,
		["true"] = true,
		["until"] = true,
		["while"] = true,
		["type"] = true,
		["typeof"] = true
	},

	builtin = {
		-- Luau Functions
		["assert"] = true,
		["error"] = true,
		["getfenv"] = true,
		["getmetatable"] = true,
		["ipairs"] = true,
		["loadstring"] = true,
		["newproxy"] = true,
		["next"] = true,
		["pairs"] = true,
		["pcall"] = true,
		["print"] = true,
		["rawequal"] = true,
		["rawget"] = true,
		["rawset"] = true,
		["select"] = true,
		["setfenv"] = true,
		["setmetatable"] = true,
		["tonumber"] = true,
		["tostring"] = true,
		["unpack"] = true,
		["xpcall"] = true,

		-- Luau Functions (Deprecated)
		["collectgarbage"] = true,

		-- Luau Variables
		["_G"] = true,
		["_VERSION"] = true,

		-- Luau Tables
		["bit32"] = true,
		["coroutine"] = true,
		["debug"] = true,
		["math"] = true,
		["os"] = true,
		["string"] = true,
		["table"] = true,
		["utf8"] = true,

		-- Roblox Functions
		["DebuggerManager"] = true,
		["delay"] = true,
		["gcinfo"] = true,
		["PluginManager"] = true,
		["require"] = true,
		["settings"] = true,
		["spawn"] = true,
		["tick"] = true,
		["time"] = true,
		["UserSettings"] = true,
		["wait"] = true,
		["warn"] = true,
		
		-- Roblox Functions (Deprecated)
		["Delay"] = true,
		["ElapsedTime"] = true,
		["elapsedTime"] = true,
		["printidentity"] = true,
		["Spawn"] = true,
		["Stats"] = true,
		["stats"] = true,
		["Version"] = true,
		["version"] = true,
		["Wait"] = true,
		["ypcall"] = true,

		-- Roblox Variables
		["File"] = true,
		["game"] = true,
		["plugin"] = true,
		["script"] = true,
		["shared"] = true,
		["workspace"] = true,

		-- Roblox Variables (Deprecated)
		["Game"] = true,
		["Workspace"] = true,

		-- Roblox Tables
		["Axes"] = true,
		["BrickColor"] = true,
		["CatalogSearchParams"] = true,
		["CFrame"] = true,
		["Color3"] = true,
		["ColorSequence"] = true,
		["ColorSequenceKeypoint"] = true,
		["DateTime"] = true,
		["DockWidgetPluginGuiInfo"] = true,
		["Enum"] = true,
		["Faces"] = true,
		["FloatCurveKey"] = true,
		["Font"] = true,
		["Instance"] = true,
		["NumberRange"] = true,
		["NumberSequence"] = true,
		["NumberSequenceKeypoint"] = true,
		["OverlapParams"] = true,
		["PathWaypoint"] = true,
		["PhysicalProperties"] = true,
		["Random"] = true,
		["Ray"] = true,
		["RaycastParams"] = true,
		["Rect"] = true,
		["Region3"] = true,
		["Region3int16"] = true,
		["RotationCurveKey"] = true,
		["task"] = true,
		["TweenInfo"] = true,
		["UDim"] = true,
		["UDim2"] = true,
		["Vector2"] = true,
		["Vector2int16"] = true,
		["Vector3"] = true,
		["Vector3int16"] = true,
	},

	libraries = {

		-- Luau Libraries
		bit32 = {
			arshift = true,
			band = true,
			bnot = true,
			bor = true,
			btest = true,
			bxor = true,
			countlz = true,
			countrz = true,
			extract = true,
			lrotate = true,
			lshift = true,
			replace = true,
			rrotate = true,
			rshift = true,
		},

		coroutine = {
			close = true,
			create = true,
			isyieldable = true,
			resume = true,
			running = true,
			status = true,
			wrap = true,
			yield = true,
		},

		debug = {
			dumpheap = true,
			info = true,
			loadmodule = true,
			profilebegin = true,
			profileend = true,
			resetmemorycategory = true,
			setmemorycategory = true,
			traceback = true,
		},

		math = {
			abs = true,
			acos = true,
			asin = true,
			atan2 = true,
			atan = true,
			ceil = true,
			clamp = true,
			cos = true,
			cosh = true,
			deg = true,
			exp = true,
			floor = true,
			fmod = true,
			frexp = true,
			ldexp = true,
			log10 = true,
			log = true,
			max = true,
			min = true,
			modf = true,
			noise = true,
			pow = true,
			rad = true,
			random = true,
			randomseed = true,
			round = true,
			sign = true,
			sin = true,
			sinh = true,
			sqrt = true,
			tan = true,
			tanh = true,

			huge = true,
			pi = true,
		},

		os = {
			clock = true,
			date = true,
			difftime = true,
			time = true,
		},

		string = {
			byte = true,
			char = true,
			find = true,
			format = true,
			gmatch = true,
			gsub = true,
			len = true,
			lower = true,
			match = true,
			pack = true,
			packsize = true,
			rep = true,
			reverse = true,
			split = true,
			sub = true,
			unpack = true,
			upper = true,
		},

		table = {
			clear = true,
			clone = true,
			concat = true,
			create = true,
			find = true,
			foreach = true,
			foreachi = true,
			freeze = true,
			getn = true,
			insert = true,
			isfrozen = true,
			maxn = true,
			move = true,
			pack = true,
			remove = true,
			sort = true,
			unpack = true,
		},

		utf8 = {
			char = true,
			codepoint = true,
			codes = true,
			graphemes = true,
			len = true,
			nfcnormalize = true,
			nfdnormalize = true,
			offset = true,

			charpattern = true,
		},

		-- Roblox Libraries
		Axes = {
			new = true,
		},

		BrickColor = {
			Black = true,
			Blue = true,
			DarkGray = true,
			Gray = true,
			Green = true,
			new = true,
			New = true,
			palette = true,
			Random = true,
			random = true,
			Red = true,
			White = true,
			Yellow = true,
		},

		CatalogSearchParams = {
			new = true,
		},

		CFrame = {
			Angles = true,
			fromAxisAngle = true,
			fromEulerAnglesXYZ = true,
			fromEulerAnglesYXZ = true,
			fromMatrix = true,
			fromOrientation = true,
			lookAt = true,
			new = true,

			identity = true,
		},

		Color3 = {
			fromHex = true,
			fromHSV = true,
			fromRGB = true,
			new = true,
			toHSV = true,
		},

		ColorSequence = {
			new = true,
		},

		ColorSequenceKeypoint = {
			new = true,
		},

		DateTime = {
			fromIsoDate = true,
			fromLocalTime = true,
			fromUniversalTime = true,
			fromUnixTimestamp = true,
			fromUnixTimestampMillis = true,
			now = true,
		},

		DockWidgetPluginGuiInfo = {
			new = true,
		},

		Enum = {},

		Faces = {
			new = true,
		},

		FloatCurveKey = {
			new = true,
		},
		
		Font = {
			fromEnum = true,
			new = true,
		},

		Instance = {
			new = true,
		},

		NumberRange = {
			new = true,
		},

		NumberSequence = {
			new = true,
		},

		NumberSequenceKeypoint = {
			new = true,
		},

		OverlapParams = {
			new = true,
		},

		PathWaypoint = {
			new = true,
		},

		PhysicalProperties = {
			new = true,
		},

		Random = {
			new = true,
		},

		Ray = {
			new = true,
		},

		RaycastParams = {
			new = true,
		},

		Rect = {
			new = true,
		},

		Region3 = {
			new = true,
		},

		Region3int16 = {
			new = true,
		},

		RotationCurveKey = {
			new = true,
		},

		task = {
			cancel = true,
			defer = true,
			delay = true,
			desynchronize = true,
			spawn = true,
			synchronize = true,
			wait = true,
		},

		TweenInfo = {
			new = true,
		},

		UDim = {
			new = true,
		},

		UDim2 = {
			fromOffset = true,
			fromScale = true,
			new = true,
		},

		Vector2 = {
			new = true,

			one = true,
			xAxis = true,
			yAxis = true,
			zero = true,
		},

		Vector2int16 = {
			new = true,
		},

		Vector3 = {
			fromAxis = true,
			FromAxis = true,
			fromNormalId = true,
			FromNormalId = true,
			new = true,

			one = true,
			xAxis = true,
			yAxis = true,
			zAxis = true,
			zero = true,
		},

		Vector3int16 = {
			new = true,
		},
	},
}

-- Filling up language.libraries.Enum table 
local enumLibraryTable = language.libraries.Enum

for _, enum in ipairs(Enum:GetEnums()) do
	enumLibraryTable[tostring(enum)] = true --TODO: Remove tostring from here once there is a better way to get the name of an Enum
end

return language
