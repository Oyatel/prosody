
local format, rep = string.format, string.rep;
local pcall = pcall;
local debug = debug;
local tostring, setmetatable, rawset, pairs, ipairs, type = 
	tostring, setmetatable, rawset, pairs, ipairs, type;
local io_open, io_write = io.open, io.write;
local math_max, rep = math.max, string.rep;
local os_getenv = os.getenv;
local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;

local config = require "core.configmanager";

local logger = require "util.logger";

module "loggingmanager"

-- The log config used if none specified in the config file
local default_logging = { { to = "console" } };

-- The actual config loggingmanager is using
local logging_config = config.get("*", "core", "log") or default_logging;

local apply_sink_rules;
local log_sink_types = setmetatable({}, { __newindex = function (t, k, v) rawset(t, k, v); apply_sink_rules(k); end; });
local get_levels;
local logging_levels = { "debug", "info", "warn", "error", "critical" }

local function add_rule(sink_config)
	local sink_maker = log_sink_types[sink_config.to];
	if sink_maker then
		if sink_config.levels and not sink_config.source then
			-- Create sink
			local sink = sink_maker(sink_config);
			
			-- Set sink for all chosen levels
			for level in pairs(get_levels(sink_config.levels)) do
				logger.add_level_sink(level, sink);
			end
		elseif sink_config.source and not sink_config.levels then
			logger.add_name_sink(sink_config.source, sink_maker(sink_config));
		elseif sink_config.source and sink_config.levels then
			local levels = get_levels(sink_config.levels);
			local sink = sink_maker(sink_config);
			logger.add_name_sink(sink_config.source,
				function (name, level, ...)
					if levels[level] then
						return sink(name, level, ...);
					end
				end);
		else
			-- All sources
			-- Create sink
			local sink = sink_maker(sink_config);
			
			-- Set sink for all levels
			for _, level in pairs(logging_levels) do
				logger.add_level_sink(level, sink);
			end
		end
	else
		-- No such sink type
	end
end

-- Search for all rules using a particular sink type,
-- and apply them
function apply_sink_rules(sink_type)
	if type(logging_config) == "table" then
		for _, sink_config in pairs(logging_config) do
			if sink_config.to == sink_type then
				add_rule(sink_config);
			end
		end
	elseif type(logging_config) == "string" and sink_type == "file" then
		-- User specified simply a filename, and the "file" sink type 
		-- was just added
	end
end



--- Helper function to get a set of levels given a "criteria" table
function get_levels(criteria, set)
	set = set or {};
	if type(criteria) == "string" then
		set[criteria] = true;
		return set;
	end
	local min, max = criteria.min, criteria.max;
	if min or max then
		local in_range;
		for _, level in ipairs(logging_levels) do
			if min == level then
				set[level] = true;
				in_range = true;
			elseif max == level then
				set[level] = true;
				return set;
			elseif in_range then
				set[level] = true;
			end	
		end
	end
	
	for _, level in ipairs(criteria) do
		set[level] = true;
	end
	return set;
end

--- Definition of built-in logging sinks ---

function log_sink_types.nowhere()
	return function () return false; end;
end

-- Column width for "source" (used by stdout and console)
local sourcewidth = 20;

function log_sink_types.stdout()
	return function (name, level, message, ...)
		sourcewidth = math_max(#name+2, sourcewidth);
		local namelen = #name;
		if ... then 
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", format(message, ...), "\n");
		else
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", message, "\n");
		end
	end	
end

do
	local do_pretty_printing = not os_getenv("WINDIR");
	
	local logstyles = {};
	if do_pretty_printing then
		logstyles["info"] = getstyle("bold");
		logstyles["warn"] = getstyle("bold", "yellow");
		logstyles["error"] = getstyle("bold", "red");
	end
	function log_sink_types.console(config)
		-- Really if we don't want pretty colours then just use plain stdout
		if not do_pretty_printing then
			return log_sink_types.stdout(config);
		end
		
		return function (name, level, message, ...)
			sourcewidth = math_max(#name+2, sourcewidth);
			local namelen = #name;
			if ... then 
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
			else
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
			end
		end
	end
end

function log_sink_types.file(config)
	local log = config.filename;
	local logfile = io_open(log, "a+");
	if not logfile then
		return function () end
	end

	local write, format, flush = logfile.write, format, logfile.flush;
	return function (name, level, message, ...)
		if ... then 
			write(logfile, name, "\t", level, "\t", format(message, ...), "\n");
		else
			write(logfile, name, "\t" , level, "\t", message, "\n");
		end
		flush(logfile);
	end;
end

function register_sink_type(name, sink_maker)
	local old_sink_maker = log_sink_types[name];
	log_sink_types[name] = sink_maker;
	return old_sink_maker;
end

return _M;