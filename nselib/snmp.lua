--- SNMP functions
--@copyright See nmaps COPYING for licence


module(...,package.seeall)

local function encodeInt(val)
   local lsb = 0
   if val > 0 then
      local valStr = ""
      while (val > 0) do
	 lsb = math.mod(val, 256)
	 valStr = valStr .. bin.pack("C", lsb)
	 val = math.floor(val/256)
      end
      if lsb > 127 then -- two's complement collision
	 valStr = valStr .. bin.pack("H", "00")
      end

      return string.reverse(valStr)
   elseif val < 0 then
      local i = 1
      local tcval = val + 256 -- two's complement
      while tcval <= 127 do
	 tcval = tcval + (math.pow(256, i) * 255)
	 i = i+1
      end
      local valStr = ""
      while (tcval > 0) do
	 lsb = math.mod(tcval, 256)
	 valStr = valStr .. bin.pack("C", lsb)
	 tcval = math.floor(tcval/256)
      end
      return string.reverse(valStr)
   else -- val == 0
      return bin.pack("x")
   end
end

local function encodeLength(val)
   if (val >= 128) then
      local valStr = ""
      while (val > 0) do
	 local lsb = math.mod(val, 256)
	 valStr = valStr .. bin.pack("C", lsb)
	 val = math.floor(val/256)
      end
      return bin.pack("CA", string.len(valStr) + 0x80, string.reverse(valStr))
      -- count down
   else 
      return bin.pack("C", val)
   end
end

function encode(val)
   local vtype = type(val)
   if (vtype == 'number') then
      local ival = encodeInt(val)
      local len = encodeLength(string.len(ival))
      return bin.pack('HAA', '02', len, ival)
   end
   if (vtype == 'string') then
      local len = encodeLength(string.len(val))
      return bin.pack('HAA', '04', len, val)
   end
   if (vtype == 'nil' or vtype == 'boolean') then
      return bin.pack('H', '05 00')
   end
   if (vtype == 'table') then -- complex data types
      if val._snmp == '06' then -- OID
	 local oidStr = bin.pack("C", val[1]*40 + val[2])
	 for i = 3, #val do
	    oidStr = oidStr .. bin.pack("C", val[i])
	 end 
	 return bin.pack("HCA", '06', #val - 1, oidStr) 
      elseif (val._snmp == '40') then -- ipAddress
	 return bin.pack("HC4", '40 04', unpack(val))
      elseif (val._snmp == '41') then -- counter
	 local cnt = encodeInt(val[1])
	 return bin.pack("HAA", val._snmp, encodeLength(string.len(cnt)), cnt)
      elseif (val._snmp == '42') then -- gauge
	 local gauge = encodeInt(val[1])
	 return bin.pack("HAA", val._snmp, encodeLength(string.len(gauge)), gauge)
      elseif (val._snmp == '43') then -- timeticks
	 local ticks = encodeInt(val[1])
	 return bin.pack("HAA", val._snmp, encodeLength(string.len(ticks)), ticks)
      elseif (val._snmp == '44') then -- opaque
	 return bin.pack("HAA", val._snmp, encodeLength(string.len(val[1])), val[1])
      end
      local encVal = ""
      for _, v in ipairs(val) do
	 encVal = encVal .. encode(v) -- todo: buffer?
      end
      local tableType = bin.pack("H", "30")
      if (val["_snmp"]) then 
	 tableType = bin.pack("H", val["_snmp"]) 
      end
      return bin.pack('AAA', tableType, encodeLength(string.len(encVal)), encVal)
   end
   return ''
end

local function decodeLength(encStr, pos)
   local elen
   pos, elen = bin.unpack('C', encStr, pos)
   if (elen > 128) then
      elen = elen - 128
      local elenCalc = 0
      local elenNext
      for i = 1, elen do
	 elenCalc = elenCalc * 256
	 pos, elenNext = bin.unpack("C", encStr, pos)
	 elenCalc = elenCalc + elenNext
      end
      elen = elenCalc
   end
   return pos, elen
end

local function decodeInt(encStr, len, pos)
   local hexStr
   pos, hexStr = bin.unpack("H" .. len, encStr, pos)
   local value = tonumber(hexStr, 16)
   if (value >= math.pow(256, len)/2) then
      value = value - math.pow(256, len)
   end
   return pos, value
end

local function decodeSeq(encStr, len, pos)
   local seq = {}
   local sPos = 1
   local i = 1
   local sStr
   pos, sStr = bin.unpack("A" .. len, encStr, pos)
   while (sPos < len) do
      sPos, newSeq = decode(sStr, sPos)
      table.insert(seq, newSeq)
      i = i + 1
   end
   return pos, seq
end

function decode(encStr, pos)
   local etype, elen
   pos, etype = bin.unpack("H1", encStr, pos)
   pos, elen = decodeLength(encStr, pos)
   if (etype == "02") then -- INTEGER
      return decodeInt(encStr, elen, pos)
      
   elseif (etype == "04") then -- STRING
      return bin.unpack("A" .. elen, encStr, pos)
      
   elseif (etype == "05") then -- NULL
      return pos, false

   elseif (etype == "06") then -- OID
      local oid = {}
      oid._snmp = '06'
      pos, octet = bin.unpack("C", encStr, pos)
      oid[2] = math.mod(octet, 40)
      octet = octet - oid[2]
      oid[1] = octet/40
      for i = 2, elen do
	 pos, oid[i+1] = bin.unpack("C", encStr, pos)
      end
      return pos, oid
   elseif (etype == "30") then -- sequence
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      return pos, seq

   elseif (etype == "A0") then -- getReq
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      seq._snmp = etype
      return pos, seq

   elseif (etype == "A1") then -- getNextReq
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      seq._snmp = etype
      return pos, seq

   elseif (etype == "A2") then -- getResponse
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      seq._snmp = etype
      return pos, seq

   elseif (etype == "A3") then -- setReq
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      seq._snmp = etype
      return pos, seq
   elseif (etype == "A4") then -- Trap
      local seq
      pos, seq = decodeSeq(encStr, elen, pos)
      seq._snmp = etype
      return pos, seq
   elseif (etype == '40') then -- App: IP-Address
      local ip = {}
      pos, ip[1], ip[2], ip[3], ip[4] = bin.unpack("C4", encStr, pos)
      ip._snmp = '40'
      return pos, ip
   elseif (etype == '41') then -- App: counter
      local cnt = {}
      pos, cnt[1] = decodeInt(encStr, elen, pos)
      cnt._snmp = '41'
      return pos, cnt
   elseif (etype == '42') then -- App: gauge
      local gauge = {}
      pos, gauge[1] = decodeInt(encStr, elen, pos)
      gauge._snmp = '42'
      return pos, gauge
   elseif (etype == '43') then -- App: TimeTicks
      local ticks = {}
      pos, ticks[1] = decodeInt(encStr, elen, pos)
      ticks._snmp = '43'
      return pos, ticks
   elseif (etype == '44') then -- App: opaque
      local opaque = {}
      pos, opaque[1] = bin.unpack("A" .. elen, encStr, pos)
      opaque._snmp = '44'
      return pos, opaque
   end
   return pos, nil
end

function dec(encStr, pos)
   local result
   local _
   _, result = decode(encStr, pos)
   return result
end

function buildPacket(PDU, version, commStr)
   local comm = nmap.registry.args.snmpcommunity
   if (not comm) then comm = nmap.registry.snmpcommunity end
   if (not comm) then comm = commStr end
   if (not comm) then comm = "public" end

   if (not version) then version = 0 end
   local packet = {}
   packet[1] = version
   packet[2] = comm
   packet[3] = PDU
   return packet
end

function buildGetRequest(options, ...)
   if not options then options = {} end

	 if not options.reqId then options.reqId = math.mod(nmap.clock_ms(), 65000) end
   if not options.err then options.err = 0 end
   if not options.errIdx then options.errIdx = 0 end

   local req = {}
   req._snmp = 'A0'
   req[1] = options.reqId
   req[2] = options.err
   req[3] = options.errIdx
   
   local payload = {}
   for i=1, select('#', ...) do
      payload[i] = {}
      payload[i][1] = select(i, ...)
      if type(payload[i][1]) == "string" then
	 payload[i][1] = str2oid(payload[i][1])
      end
      payload[i][2] = false
   end
   req[4] = payload
   return req
end

function buildGetNextRequest(options, ...)
   if not options then options = {} end

	 if not options.reqId then options.reqId = math.mod(nmap.clock_ms(), 65000) end
   if not options.err then options.err = 0 end
   if not options.errIdx then options.errIdx = 0 end

   local req = {}
   req._snmp = 'A1'
   req[1] = options.reqId
   req[2] = options.err
   req[3] = options.errIdx
   
   local payload = {}
   for i=1, select('#', ...) do
      payload[i] = {}
      payload[i][1] = select(i, ...)
      if type(payload[i][1]) == "string" then
	 payload[i][1] = str2oid(payload[i][1])
      end
      payload[i][2] = false
   end
   req[4] = payload
   return req
end

function buildSetRequest(options, oid, value) -- directly uses value if value is a table
   if not options then options = {} end

	 if not options.reqId then options.reqId = math.mod(nmap.clock_ms(), 65000) end
   if not options.err then options.err = 0 end
   if not options.errIdx then options.errIdx = 0 end

   local req = {}
   req._snmp = 'A3'
   req[1] = options.reqId
   req[2] = options.err
   req[3] = options.errIdx

   if (type(value) == "table") then
      req[4] = value
   else 
      local payload = {}
      if (type(oid) == "string") then
	 payload[1] = str2oid(oid)
      else
	 payload[1] = oid
      end
      payload[2] = value
      req[4] = {}
      req[4][1] = payload
   end
   return req
end

function buildTrap(enterpriseOid, agentIp, genTrap, specTrap, timeStamp)
   local req = {}
   req._snmp = 'A4'
   if (type(enterpriseOid) == "string") then 
      req[1] = str2oid(enterpriseOid)
   else
      req[1] = enterpriseOid
   end
   req[2] = {}
   req[2]._snmp = '40'
   for n in string.gmatch(agentIp, "%d+") do
      table.insert(req[2], tonumber(n))
   end
   req[3] = genTrap
   req[4] = specTrap

   req[5] = {}
   req[5]._snmp = '43'
   req[5][1] = timeStamp

   req[6] = {}

   return req
end

function buildGetResponse(options, oid, value) -- directly uses value if value is a table
   if not options then options = {} end

   -- if really a response, should use reqId of request!
   if not options.reqId then options.reqId = math.mod(nmap.clock_ms(), 65000) end
   if not options.err then options.err = 0 end
   if not options.errIdx then options.errIdx = 0 end

   local resp = {}
   resp._snmp = 'A2'
   resp[1] = options.reqId
   resp[2] = options.err
   resp[3] = options.errIdx

   if (type(value) == "table") then
      resp[4] = value
   else 

      local payload = {}
      if (type(oid) == "string") then
	 payload[1] = str2oid(oid)
      else
	 payload[1] = oid
      end
      payload[2] = value
      resp[4] = {}
      resp[4][1] = payload
   end
   return resp
end


function str2oid(oidStr)
   local oid = {}
   for n in string.gmatch(oidStr, "%d+") do
      table.insert(oid, tonumber(n))
   end
   oid._snmp = '06'
   return oid
end


function oid2str(oid)
   if (type(oid) ~= "table") then return 'invalid oid' end
   return table.concat(oid, '.')
end


function ip2str(ip)
   if (type(ip) ~= "table") then return 'invalid ip' end
   return table.concat(ip, '.')
end

function str2ip(ipStr)
   local ip = {}
   for n in string.gmatch(ipStr, "%d+") do
      table.insert(ip, tonumber(n))
   end
   ip._snmp = '40'
   return ip
end

function fetchResponseValues(resp)
   if (type(resp) == "string") then
      local _, resp = decode(resp)
   end

   if (type(resp) ~= "table") then 
      return {}
   end

   local varBind
   if (resp._snmp and resp._snmp == 'A2') then
      varBind = resp[4]
   elseif (resp[3]._snmp and resp[3]._snmp == 'A2') then
      varBind = resp[3][4]
   end

   if (varBind and type(varBind) == "table") then
      local result = {}
      for k, v in ipairs(varBind) do
	 local val = v[2]
	 if (type(v[2]) == "table") then
	    if (v[2]._snmp == '40') then
	       val = v[2][1] .. '.' .. v[2][2] .. '.' .. v[2][3] .. '.' .. v[2][4]
	    elseif (v[2]._snmp == '41') then
	       val = v[2][1]
	    elseif (v[2]._snmp == '42') then
	       val = v[2][1]
	    elseif (v[2]._snmp == '43') then
	       val = v[2][1]
	    elseif (v[2]._snmp == '44') then
	       val = v[2][1]
	    end
	 end
	 table.insert(result, {val, oid2str(v[1]), v[1]})
      end
      return result
   end
   return {}
end

function fetchFirst(response)
   local result = fetchResponseValues(response)
   if type(result) == "table" and result[1] and result[1][1] then return result[1][1]
   else return nil
   end
end
