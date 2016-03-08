local _M = {}

_M.version = "0.6.0"

local cjson         = require("cjson")
local file_logger   = require("inc.resty.logger.file")
local iputils       = require("inc.resty.iputils")
local socket_logger = require("inc.resty.logger.socket")

local cidr_lib  = require("lib.cidr")
local logger    = require("lib.log")
local operators = require("lib.operators")
local request   = require("lib.request")
local storage   = require("lib.storage")
local util      = require("lib.util")

_M.alter_actions = { ACCEPT = true, DENY = true }

_M.collections = {
	access = function(FW, collections, ctx)
		local request_headers       = ngx.req.get_headers()
		local request_uri_args      = ngx.req.get_uri_args()
		local request_post_args     = request.parse_request_body(FW, request_headers)
		local request_cookies       = request.cookies() or {}
		local request_common_args   = request.common_args(FW, { request_uri_args, request_post_args, request_cookies })

		collections.IP                   = ngx.var.remote_addr
		collections.HTTP_VERSION         = ngx.req.http_version()
		collections.METHOD               = ngx.req.get_method()
		collections.URI                  = ngx.var.uri
		collections.URI_ARGS             = request_uri_args
		collections.REQUEST_HEADERS      = request_headers
		collections.USER_AGENT           = ngx.var.http_user_agent
		collections.COOKIES              = request_cookies
		collections.REQUEST_BODY         = request_post_args
		collections.REQUEST_ARGS         = request_common_args
		collections.VAR                  = function(FW, opts, collections) return storage.get_var(FW, opts.value, collections) end
		collections.TX                   = function(FW, opts, collections) return storage.get_var(FW, opts.value, collections, ctx.tx) end
		collections.NGX_VAR              = ngx.var
		collections.SCORE                = function() return ctx.score end
		collections.SCORE_THRESHOLD      = function(FW) return FW._score_threshold end
	end,
	header_filter = function(FW, collections)
		local response_headers = ngx.resp.get_headers()

		collections.RESPONSE_HEADERS      = response_headers
		collections.STATUS                = ngx.status
	end,
	body_filter = function(FW, collections, ctx)
		if ctx.buffers == nil then
			ctx.buffers = {}
			ctx.nbuffers = 0
		end

		local data  = ngx.arg[1]
		local eof   = ngx.arg[2]
		local index = ctx.nbuffers + 1

		local res_length = tonumber(collections.RESPONSE_HEADERS["content-length"])
		local res_type   = collections.RESPONSE_HEADERS["content-type"]

		if (not res_length or res_length > FW._res_body_max_size) then
			ctx.short_circuit = not eof
			return
		end

		if (not res_type or not util.table_has_key(res_type, FW._res_body_mime_types)) then
			ctx.short_circuit = not eof
			return
		end

		if data then
			ctx.buffers[index] = data
			ctx.nbuffers = index
		end

		if not eof then
			-- Send nothing to the client yet.
			ngx.arg[1] = nil

			-- no need to process further at this point
			ctx.short_circuit = true
			return
		else
			collections.RESPONSE_BODY = table.concat(ctx.buffers, '')
			ngx.arg[1] = collections.RESPONSE_BODY
		end
	end
}

_M.parse_collection = {
	specific = function(FW, collection, value)
		logger.log(FW, "Parse collection is getting a specific value: " .. value)
		return collection[value]
	end,
	ignore = function(FW, collection, value)
		logger.log(FW, "Parse collection is ignoring a value: " .. value)
		local _collection = {}
		_collection = util.table_copy(collection)
		_collection[value] = nil
		return _collection
	end,
	keys = function(FW, collection)
		logger.log(FW, "Parse collection is getting the keys")
		return util.table_keys(collection)
	end,
	values = function(FW, collection)
		logger.log(FW, "Parse collection is getting the values")
		return util.table_values(collection)
	end,
	all = function(FW, collection)
		local n = 0
		local _collection = {}
		for _, key in ipairs(util.table_keys(collection)) do
			n = n + 1
			_collection[n] = key
		end
		for _, value in ipairs(util.table_values(collection)) do
			n = n + 1
			_collection[n] = value
		end
		return _collection
	end
}

_M.actions = {
	ACCEPT = function(FW, ctx)
		logger.log(FW, "Rule action was ACCEPT, so ending this phase with ngx.OK")
		if (FW._mode == "ACTIVE") then
			ngx.exit(ngx.OK)
		end
	end,
	CHAIN = function(FW, ctx)
		logger.log(FW, "Chaining (pre-processed)")
	end,
	SKIP = function(FW, ctx)
		logger.log(FW, "Skipping (pre-processed)")
	end,
	SCORE = function(FW, ctx)
		local new_score = ctx.score + ctx.rule_score
		logger.log(FW, "New score is " .. new_score)
		ctx.score = new_score
	end,
	DENY = function(FW, ctx)
		logger.log(FW, "Rule action was DENY, so telling nginx to quit (from the lib!)")
		if (FW._mode == "ACTIVE") then
			ngx.exit(ngx.HTTP_FORBIDDEN)
		end
	end,
	IGNORE = function(FW)
		logger.log(FW, "Ignoring rule for now")
	end,
	SETVAR = function(FW, ctx, collections)
		storage.set_var(FW, ctx, collections)
	end,
	SETTX = function(FW, ctx, collections)
		storage.set_var(FW, ctx, collections, true)
	end,
}

_M.transform = {
	base64_decode = function(FW, value)
		logger.log(FW, "Decoding from base64: " .. tostring(value))
		local t_val = ngx.decode_base64(tostring(value))
		if (t_val) then
			logger.log(FW, "Decode successful, decoded value is " .. t_val)
			return t_val
		else
			logger.log(FW, "Decode unsuccessful, returning original value " .. value)
			return value
		end
	end,
	base64_encode = function(FW, value)
		logger.log(FW, "Encoding to base64: " .. tostring(value))
		local t_val = ngx.encode_base64(value)
		logger.log(FW, "Encoded value is " .. t_val)
		return t_val
	end,
	compress_whitespace = function(FW, value)
		return ngx.re.gsub(value, [=[\s+]=], ' ', FW._pcre_flags)
	end,
	html_decode = function(FW, value)
		local str = ngx.re.gsub(value, [=[&lt;]=], '<', FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&gt;]=], '>', FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&quot;]=], '"', FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&apos;]=], "'", FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&#(\d+);]=], function(n) return string.char(n[1]) end, FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&#x(\d+);]=], function(n) return string.char(tonumber(n[1],16)) end, FW._pcre_flags)
		str = ngx.re.gsub(str, [=[&amp;]=], '&', FW._pcre_flags)
		logger.log(FW, "html decoded value is " .. str)
		return str
	end,
	lowercase = function(FW, value)
		return string.lower(tostring(value))
	end,
	remove_comments = function(FW, value)
		return ngx.re.gsub(value, [=[\/\*(\*(?!\/)|[^\*])*\*\/]=], '', FW._pcre_flags)
	end,
	remove_whitespace = function(FW, value)
		return ngx.re.gsub(value, [=[\s+]=], '', FW._pcre_flags)
	end,
	replace_comments = function(FW, value)
		return ngx.re.gsub(value, [=[\/\*(\*(?!\/)|[^\*])*\*\/]=], ' ', FW._pcre_flags)
	end,
	uri_decode = function(FW, value)
		return ngx.unescape_uri(value)
	end,
}

_M.write_log_events = {
	error = function(FW, t)
		ngx.log(FW._event_log_level, cjson.encode(t))
	end,
	file = function(FW, t)
		if (not file_logger.initted()) then
			file_logger.init({
				path           = FW._event_log_target_path,
				flush_limit    = FW._event_log_buffer_size,
				periodic_flush = FW._event_log_periodic_flush
			})
		end

		file_logger.log(cjson.encode(t) .. "\n")
	end,
	socket = function(FW, t)
		if (not socket_logger.initted()) then
			socket_logger.init({
				host           = FW._event_log_target_host,
				port           = FW._event_log_target_port,
				sock_type      = FW._event_log_socket_proto,
				flush_limit    = FW._event_log_buffer_size,
				periodic_flush = FW._event_log_periodic_flush
			})
		end

		socket_logger.log(cjson.encode(t) .. "\n")
	end
}

_M.operators = {
	REGEX          = function(FW, subject, pattern) return operators.regex_match(FW, subject, pattern) end,
	NOT_REGEX      = function(FW, subject, pattern) return not operators.regex_match(FW, subject, pattern) end,
	EQUALS         = function(FW, a, b) return operators.equals(a, b) end,
	NOT_EQUALS     = function(FW, a, b) return not operators.equals(a, b) end,
	GREATER        = function(FW, a, b) return operators.greater(a, b) end,
	NOT_GREATER    = function(FW, a, b) return not operators.greater(a, b) end,
	EXISTS         = function(FW, needle, haystack) return util.table_has_value(needle, haystack) end,
	NOT_EXISTS     = function(FW, needle, haystack) return not util.table_has_value(needle, haystack) end,
	CONTAINS       = function(FW, haystack, needle) return util.table_has_value(needle, haystack) end,
	NOT_CONTAINS   = function(FW, haystack, needle) return not util.table_has_value(needle, haystack) end,
	PM             = function(FW, needle, haystack, ctx) return operators.ac_lookup(needle, haystack, ctx) end,
	NOT_PM         = function(FW, needle, haystack, ctx) return not operators.ac_lookup(needle, haystack, ctx) end,
	CIDR_MATCH     = function(FW, ip, cidrs) return operators.cidr_match(ip, cidrs) end,
	NOT_CIDR_MATCH = function(FW, ip, cidrs) return not operators.cidr_match(ip, cidrs) end,
}


_M.set_option = {
	ignore_ruleset = function(FW, value)
		local t = FW._ignore_ruleset
		FW._ignore_ruleset[#t + 1] = value
		FW.need_merge = true
	end,
	add_ruleset = function(FW, value)
		local t = FW._add_ruleset
		FW._add_ruleset[#t + 1] = value
		FW.need_merge = true
	end,
	ignore_rule = function(FW, value)
		FW._ignore_rule[value] = true
	end,
	disable_pcre_optimization = function(FW, value)
		if (value == true) then
			FW._pcre_flags = 'i'
		end
	end,
	storage_zone = function(FW, value)
		if (not ngx.shared[value]) then
			logger.fatal_fail("Attempted to set FreeWAF storage zone as " .. tostring(value) .. ", but that lua_shared_dict does not exist")
		end
		FW._storage_zone = value
	end,
	allowed_content_types = function(FW, value)
		FW._allowed_content_types[value] = true
	end,
	res_body_mime_types = function(FW, value)
		FW._res_body_mime_types[value] = true
	end,
	event_log_ngx_vars = function(FW, value)
		local t = FW._event_log_ngx_vars
		FW._event_log_ngx_vars[#t + 1] = value
	end,
	process_cidr = function(FW, value)
		if (not cidr_lib.cidrs[value]) then
			local lower, upper = iputils.parse_cidr(value)
			cidr_lib.cidrs[value] = { lower, upper }
		end
	end,
}

return _M
