
local socket = require "socket"
local server = require "net.server"
local url_parse = require "socket.url".parse;

local connlisteners_start = require "net.connlisteners".start;
local connlisteners_get = require "net.connlisteners".get;
local listener;

local t_insert, t_concat = table.insert, table.concat;
local s_match, s_gmatch = string.match, string.gmatch;
local tonumber, tostring, pairs = tonumber, tostring, pairs;

local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });
local urlencode = function (s) return s and (s:gsub("%W", function (c) return string.format("%%%x", c:byte()); end)); end

local log = require "util.logger".init("httpserver");

local http_servers = {};

module "httpserver"

local default_handler;

local function expectbody(reqt)
    return reqt.method == "POST";
end

local function send_response(request, response)
	-- Write status line
	local resp;
	if response.body then
		log("debug", "Sending response to %s: %s", request.id, response.body);
		resp = { "HTTP/1.0 ", response.status or "200 OK", "\r\n"};
		local h = response.headers;
		if h then
			for k, v in pairs(h) do
				t_insert(resp, k);
				t_insert(resp, ": ");
				t_insert(resp, v);
				t_insert(resp, "\r\n");
			end
		end
		if response.body and not (h and h["Content-Length"]) then
			t_insert(resp, "Content-Length: ");
			t_insert(resp, #response.body);
			t_insert(resp, "\r\n");
		end
		t_insert(resp, "\r\n");
		
		if response.body and request.method ~= "HEAD" then
			t_insert(resp, response.body);
		end
	else
		-- Response we have is just a string (the body)
		log("debug", "Sending response to %s: %s", request.id, response);
		
		resp = { "HTTP/1.0 200 OK\r\n" };
		t_insert(resp, "Connection: close\r\n");
		t_insert(resp, "Content-Length: ");
		t_insert(resp, #response);
		t_insert(resp, "\r\n\r\n");
		
		t_insert(resp, response);
	end
	request.write(t_concat(resp));
	if not request.stayopen then
		request:destroy();
	end
end

local function call_callback(request, err)
	if request.handled then return; end
	request.handled = true;
	local callback = request.callback;
	if not callback and request.path then
		local path = request.url.path;
		local base = path:match("^/([^/?]+)");
		if not base then
			base = path:match("^http://[^/?]+/([^/?]+)");
		end
		
		callback = (request.server and request.server.handlers[base]) or default_handler;
		if callback == default_handler then
			log("debug", "Default callback for this request (base: "..tostring(base)..")")
		end
	end
	if callback then
		if err then
			log("debug", "Request error: "..err);
			if not callback(nil, err, request) then
				destroy_request(request);
			end
			return;
		end
		
		local response = callback(request.method, request.body and t_concat(request.body), request);
		if response then
			if response == true then
				-- Keep connection open, we will reply later
				log("warn", "Request %s left open, on_destroy is %s", request.id, tostring(request.on_destroy));
			else
				-- Assume response
				send_response(request, response);
				destroy_request(request);
			end
		else
			log("debug", "Request handler provided no response, destroying request...");
			-- No response, close connection
			destroy_request(request);
		end
	end
end

local function request_reader(request, data, startpos)
	if not data then
		if request.body then
			call_callback(request);
		else
			-- Error.. connection was closed prematurely
			call_callback(request, "connection-closed");
		end
		-- Here we force a destroy... the connection is gone, so we can't reply later
		destroy_request(request);
		return;
	end
	if request.state == "body" then
		log("debug", "Reading body...")
		if not request.body then request.body = {}; request.havebodylength, request.bodylength = 0, tonumber(request.responseheaders["content-length"]); end
		if startpos then
			data = data:sub(startpos, -1)
		end
		t_insert(request.body, data);
		if request.bodylength then
			request.havebodylength = request.havebodylength + #data;
			if request.havebodylength >= request.bodylength then
				-- We have the body
				call_callback(request);
			end
		end
	elseif request.state == "headers" then
		log("debug", "Reading headers...")
		local pos = startpos;
		local headers = request.responseheaders or {};
		for line in data:gmatch("(.-)\r\n") do
			startpos = (startpos or 1) + #line + 2;
			local k, v = line:match("(%S+): (.+)");
			if k and v then
				headers[k:lower()] = v;
--				log("debug", "Header: "..k:lower().." = "..v);
			elseif #line == 0 then
				request.responseheaders = headers;
				break;
			else
				log("debug", "Unhandled header line: "..line);
			end
		end
		
		if not expectbody(request) then 
			call_callback(request);
			return;
		end
		
		-- Reached the end of the headers
		request.state = "body";
		if #data > startpos then
			return request_reader(request, data:sub(startpos, -1));
		end
	elseif request.state == "request" then
		log("debug", "Reading request line...")
		local method, path, http, linelen = data:match("^(%S+) (%S+) HTTP/(%S+)\r\n()", startpos);
		if not method then
			return call_callback(request, "invalid-status-line");
		end
		
		request.method, request.path, request.httpversion = method, path, http;
		
		request.url = url_parse(request.path);
		
		log("debug", method.." request for "..tostring(request.path) .. " on port "..request.handler.serverport());
		
		if request.onlystatus then
			if not call_callback(request) then
				return;
			end
		end
		
		request.state = "headers";
		
		if #data > linelen then
			return request_reader(request, data:sub(linelen, -1));
		end
	end
end

-- The default handler for requests
default_handler = function (method, body, request)
	log("debug", method.." request for "..tostring(request.path) .. " on port "..request.handler.serverport());
	return { status = "404 Not Found", 
			headers = { ["Content-Type"] = "text/html" },
			body = "<html><head><title>Page Not Found</title></head><body>Not here :(</body></html>" };
end


function new_request(handler)
	return { handler = handler, conn = handler.socket, 
			write = handler.write, state = "request", 
			server = http_servers[handler.serverport()],
			send = send_response,
			destroy = destroy_request,
			id = tostring{}:match("%x+$")
			 };
end

function destroy_request(request)
	log("debug", "Destroying request %s", request.id);
	listener = listener or connlisteners_get("httpserver");
	if not request.destroyed then
		request.destroyed = true;
		if request.on_destroy then
			log("debug", "Request has destroy callback");
			request.on_destroy(request);
		else
			log("debug", "Request has no destroy callback");
		end
		request.handler.close()
		if request.conn then
			listener.disconnect(request.conn, "closed");
		end
	end
end

function new(params)
	local http_server = http_servers[params.port];
	if not http_server then
		http_server = { handlers = {} };
		http_servers[params.port] = http_server;
		-- We weren't already listening on this port, so start now
		connlisteners_start("httpserver", params);
	end
	if params.base then
		http_server.handlers[params.base] = params.handler;
	end
end

_M.request_reader = request_reader;
_M.send_response = send_response;
_M.urlencode = urlencode;

return _M;