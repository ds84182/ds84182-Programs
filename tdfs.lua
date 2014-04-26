--tdfs--
-- Byte 0-3: "TDFS" in ascii
-- Byte 4-7: Int describing number of file blocks
-- Byte 8-11: Int describing file table entry number
-- Byte 12-15: Int describing the pointer to the first root entry
-- Byte 16-31: Name of volume in ascii

--after the volume name, we get file entries

--file entries:
-- Byte 0: "E" E is for entry!
-- Byte 1-16: File name
-- Byte 17: 0 - Empty, 1 - File, 2 - Directory
-- Byte 18-19: Pointer to file data block or first directory entry
-- Byte 20-21: Pointer to next entry, if this equals 0xFFFF, then this is the ending entry
-- Byte 22-23: Pointer to previous entry, if this equals 0xFFFF, then this is the starting entry

--so we get a ton of file entries, here comes file data
--the file data is split into blocks of 1024
--first, we get the allocation map
-- Byte 0-(#filedatablocks/8): Bytes with each bit describing the current allocation status of each block

--after that, you have file data
-- Byte 0: "B" B is for block!
-- Byte 1-2: Short describing next block, if it equals 0xFFFF then we are at the last block
-- Byte 3-4: Short describing length of block data
-- Byte 5-1023: Data, only bytelen is used

local tdfs = {}
local term = _test and setmetatable({write=function(v) io.write("\r"..v) end},{__index=function() return function() end end}) or require 'term'
local bit = _test and require "bit" or bit32 --forreasons
local component = _test and {} or require "component"

function tu4(n)
	return string.char(bit.band(n,0xFF),bit.rshift(bit.band(n,0xFF00),8),bit.rshift(bit.band(n,0xFF0000),16),bit.rshift(bit.band(n,0xFF000000),24))
end

function tu2(n)
	return string.char(bit.band(n,0xFF),bit.rshift(bit.band(n,0xFF00),8))
end

function tu1(n)
	return string.char(bit.band(n,0xFF))
end

function fu4(s)
	local b1,b2,b3,b4 = string.byte(s,1,4)
	return bit.bor(b1,bit.lshift(b2,8),bit.lshift(b3,16),bit.lshift(b4,24))
end

function fu2(s)
	local b1,b2 = string.byte(s,1,2)
	return bit.bor(b1,bit.lshift(b2,8))
end

function fu1(s)
	return string.byte(s)
end

-- Compatibility: Lua-5.1
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
	 table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

function split_path(str)
   return split(str,'[\\/]+')
end

function format(td)
	--format the tape drive
	print("Formatting "..td.address.."...")
	local size = td.getSize()
	local fent = 256
	local datsize = 32+(fent*24) --calculate the size
	local blocks = 0
	do
		local i = 0
		while true do
			if datsize+math.ceil(i/8)+(i*1024) > size then
				datsize = datsize+math.ceil(i/8)+(i*1024)
				blocks = i
				break
			else
				i = i+1
			end
		end
	end
	print("Overall size: "..datsize)
	print("File entries: "..fent)
	print("Data blocks: "..blocks)
	
	td.seek(-size)
	
	--write header
	print("Writing header")
	td.write("TDFS")
	td.write(tu4(blocks))
	td.write(tu4(fent))
	td.write(tu4(0xFFFF))
	td.write("TDFS Volume\0\0\0\0\0")
	print("Writing file entries")
	
	local data = ("E".."\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0".."\0\0\0\255\255\255\255"):rep(fent)
	td.write(data)
	
	print("Writing allocation map")
	td.write(("\0"):rep(math.ceil(blocks/8)))
	
	print("Formatting data blocks")
	local dblk = ("B\255\255"..("\0"):rep(1021)):rep(8) --just to fit in that data size byte
	for i=1, blocks, 8 do
		local x,y = term.getCursor()
		term.setCursor(1, y)
		term.write("Wrote "..i.."/"..blocks.." ("..math.ceil(i/blocks*100).."%) blocks")
		td.write(dblk)
	end
	local x,y = term.getCursor()
	term.setCursor(1, y)
	term.write("Wrote "..blocks.."/"..blocks.." ("..math.ceil(blocks/blocks*100).."%) blocks")
	print()
end

function isValidTDFS(td)
	td.seek(-td.getSize())
	local sig = td.read(4)
	return sig == "TDFS"
end

function loadTDFS(td,verbose)
	local print = verbose and print or function() end
	assert(isValidTDFS(td),"Tape in drive not a valid TDFS")
	-- Load up the volume for file operations --
	local files
	-- the above is a table that contains files in a tree --
	-- by this point, we know that the tape is valid --
	local blocks = fu4(td.read(4))
	local fent = fu4(td.read(4))
	local fdatptr = 32+(fent*24)+math.ceil(blocks/8)
	local startingFE = fu4(td.read(4))
	local name = td.read(16):match("^(.-)\0*$")
	
	-- now, load file entries --
	local fei = 0 -- file entry index
	local fents = {}
	-- load all file entries into memory --
	print("Loading all file entries into memory")
	local fentdatas = td.read(24*fent)
	local datasidx = 1
	local function rdstr(n)
		datasidx = datasidx+n
		return fentdatas:sub(datasidx-n,datasidx-1)
	end
	while fei < fent do
		local fe = {}
		local st = rdstr(1)
		if st ~= "E" then
			error("Invalid entry "..fei..": "..st)
		end
		fe.name = rdstr(16):match("^(.-)\0*$") or ""
		fe.type = rdstr(1):byte()
		fe.dptr = fu2(rdstr(2))
		fe.next = fu2(rdstr(2))
		fe.prev = fu2(rdstr(2))
		fe.index = fei
		fe[1] = fe.type == 1 and "file" or fe.type == 2 and "dir" or "empty"
		fents[fei] = fe
		fei = fei+1
	end
	
	files = {"dir",
		name = "__ROOT__",
		type = 2,
		dptr = startingFE,
		next = 0xFFFF,
		prev = 0xFFFF,
		index= -1,
	}
	fents[-1] = files
	
	local function getFirstEmptyEntry()
		for i=0, fent-1 do
			if fents[i].type == 0 then
				return fents[i]
			end
		end
		error("No more empty File Entries!")
	end
	
	local function writeFileEntry(i)
		print("Writing file entry "..i)
		td.seek(-td.getSize())
		if i > -1 then
			td.seek(32+(i*24))
			local fe = fents[i]
			local n = fe.name:sub(1,16)
			if #n < 16 then n = n..("\0"):rep(16-#n) end
			td.write("E"..n..tu1(fe.type)..tu2(fe.dptr)..tu2(fe.next)..tu2(fe.prev))
		else
			--update root
			td.seek(12)
			td.write(tu4(files.dptr))
		end
	end
	
	local function getEntry(parent,name)
		local cur = parent.dptr
		if cur == 0xFFFF then return nil end
		while fents[cur].name ~= name do
			print(cur,fents[cur].name)
			cur = fents[cur].next
			if cur == 0xFFFF then return nil end
		end
		return fents[cur].name == name and cur or nil
	end
	
	local function getLastEntry(parent)
		local cur = parent.dptr
		if cur == 0xFFFF then return nil end
		while fents[cur].next ~= 0xFFFF do
			cur = fents[cur].next
		end
		return cur
	end
	
	local function traversePath(parent,pt)
		--traverse the path
		for i=1, #pt do
			local index = getEntry(parent,pt[i])
			if index == nil then return nil end
			parent = fents[index]
		end
		return parent
	end
	
	-- load it
	local alloc = {}
	print("Loading allocation map")
	local ad = td.read(math.ceil(blocks/8))
	for i=1, math.ceil(blocks/8) do
		local b = ad:byte(i)
		alloc[#alloc+1] = bit.band(b,0x1) == 0x1
		alloc[#alloc+1] = bit.band(b,0x2) == 0x2
		alloc[#alloc+1] = bit.band(b,0x4) == 0x4
		alloc[#alloc+1] = bit.band(b,0x8) == 0x8
		alloc[#alloc+1] = bit.band(b,0x10) == 0x10
		alloc[#alloc+1] = bit.band(b,0x20) == 0x20
		alloc[#alloc+1] = bit.band(b,0x40) == 0x40
		alloc[#alloc+1] = bit.band(b,0x80) == 0x80
	end
	
	local function getFirstUnallocBlock()
		for i=1, #alloc do
			if not alloc[i] then return i-1 end
		end
		error("No more unalloc'd blocks")
	end
	
	local function deallocBlock(i)
		td.seek(-td.getSize())
		td.seek(fdatptr+(i*1024)) --seek directly to block
		td.write("B"..tu2(i)..tu2(0))
		alloc[i+1] = false
	end
	
	local function writeAllocData()
		print("Writing allocation data to tape...")
		td.seek(-td.getSize())
		td.seek(32+(fent*24))
		local dat = ""
		for i=1, #alloc, 8 do
			local n = 0
			n = n+(alloc[i] and 0x1 or 0)
			n = n+(alloc[i+1] and 0x2 or 0)
			n = n+(alloc[i+2] and 0x4 or 0)
			n = n+(alloc[i+3] and 0x8 or 0)
			n = n+(alloc[i+4] and 0x10 or 0)
			n = n+(alloc[i+5] and 0x20 or 0)
			n = n+(alloc[i+6] and 0x40 or 0)
			n = n+(alloc[i+7] and 0x80 or 0)
			dat = dat..string.char(n)
		end
		td.write(dat)
	end
	
	local function writeDataToBlock(i,dat)
		td.seek(-td.getSize())
		td.seek(fdatptr+(i*1024)+3) --seek directly to block
		td.write(tu2(#dat)..dat)
		alloc[i+1] = true
	end
	
	local function readDataFromBlock(i)
		td.seek(-td.getSize())
		td.seek(fdatptr+(i*1024)+3) --seek directly to block
		local len = fu2(td.read(2))
		return td.read(math.min(len,1019))
	end
	
	local function linkAndWriteDataToBlock(i,link,dat)
		td.seek(-td.getSize())
		td.seek(fdatptr+(i*1024)+1) --seek directly to block
		td.write(tu2(link)..tu2(#dat)..dat)
		alloc[i+1] = true
	end
	
	local fs = {}
	
	function fs.writeToFile(file,data)
		print("Writing "..#data.." bytes to "..file)
		--this function doesn't make any handles and crap
		local pt = split_path(file)
		local child = table.remove(pt,#pt)
		local parent = assert(traversePath(files,pt),file..": Directory not found")
		local fe = getEntry(parent,child)
		
		if not fe then
			print("Creating files")
			fe = getFirstEmptyEntry()
			local blk = getFirstUnallocBlock()
			print(blk)
			--construct a file entry
			fe[1] = "file"
			fe.name = child
			fe.dptr = blk
			fe.next = 0xFFFF -- we are currently the last entry
			fe.prev = 0xFFFF
			fe.type = 1
			--get last file entry in directory
			local lfe = getLastEntry(parent)
			if lfe then
				lfe = fents[lfe]
				lfe.next = fe.index
				writeFileEntry(lfe.index)
				fe.prev = lfe.index
			else
				--we are the first in the parent
				parent.dptr = fe.index
				writeFileEntry(parent.index)
			end
		else
			fe = fents[fe]
		end
		
		--write blocks
		local blocks = {} -- get the blocks used by this file entry
		local current = fe.dptr
		while true do
			td.seek(-td.getSize())
			td.seek(fdatptr+(current*1024)) --seek directly to block
			assert(td.read(1) == "B","Invalid block "..fdatptr..", "..current)
			blocks[#blocks+1] = current
			local nxt = fu2(td.read(2))
			if nxt ~= 0xFFFF then current = nxt else break end
		end
		
		-- after getting blocks, format block headers, dealloc, and then write data from the first block --
		for i, v in ipairs(blocks) do
			deallocBlock(v)
		end
		
		--data writing
		while #data > 0 do
			local nd = data:sub(1, 1018)
			data = data:sub(1019)
			if blocks[2] == nil and #data > 0 then
				blocks[2] = getFirstUnallocBlock()
			end
			local bid = table.remove(blocks,1)
			print("Writing "..#nd.." bytes to block "..bid)
			linkAndWriteDataToBlock(bid,blocks[1] or 0xFFFF,nd)
		end
		writeAllocData()
		writeFileEntry(fe.index)
	end
	
	function fs.readFromFile(file)
		--this function doesn't make any handles and crap
		--traverse the path
		local pt = split_path(file)
		local child = table.remove(pt,#pt)
		local parent = traversePath(files,pt)
		local fe = getEntry(parent,child)
		
		if not fe then
			error(file..": File does not exist")
		else
			fe = fents[fe]
		end
		
		local blocks = {} -- get the blocks used by this file entry
		local current = fe.dptr
		--print((require "serialization").serialize(fe))
		while true do
			td.seek(-td.getSize())
			td.seek(fdatptr+(current*1024)) --seek directly to block
			assert(td.read(1) == "B","Invalid block "..fdatptr..", "..current)
			blocks[#blocks+1] = current
			local nxt = fu2(td.read(2))
			if nxt ~= 0xFFFF then current = nxt else break end
		end
		
		print("Reading data from "..#blocks.." blocks")
		local data = ""
		for i, v in ipairs(blocks) do
			data = data..readDataFromBlock(v)
		end
		return data
	end
	
	function fs.remove(file)
		local pt = split_path(file)
		local child = table.remove(pt,#pt)
		local parent = assert(traversePath(files,pt),file..": Directory not found")
		local fe = getEntry(parent,child)
		
		if not fe then
			error(file..": File does not exist")
		else
			fe = fents[fe]
		end
		
		if fe.prev ~= 0xFFFF then
			fents[fe.prev].next = fe.next
			writeFileEntry(fe.prev)
		else
			--we were the first file
			parent.dptr = 0xFFFF
			writeFileEntry(parent.index)
		end
		
		if fe.next ~= 0xFFFF then
			fents[fe.next].prev = fe.prev
			writeFileEntry(fe.next)
		end
		
		local blocks = {} -- get the blocks used by this file entry
		local current = fe[3] and fe[3].dptr or fe.dptr
		while true do
			td.seek(-td.getSize())
			td.seek(fdatptr+(current*1024)) --seek directly to block
			assert(td.read(1) == "B","Invalid block "..fdatptr..", "..current)
			local nxt = fu2(td.read(2))
			if nxt == 0xFFFF then blocks[#blocks+1] = nxt break end
		end
		
		for i, v in ipairs(blocks) do
			deallocBlock(v)
		end
		
		fe[1] = "empty"
		fe.name = ""
		fe.dptr = 0xFFFF
		fe.next = 0xFFFF
		fe.prev = 0xFFFF
		fe.type = 0
		writeAllocData()
		writeFileEntry(fe.index)
		return true
	end
	
	function fs.makeDirectory(path)
		local pt = split_path(path)
		local child = table.remove(pt,#pt)
		local parent = traversePath(files,pt)
		local fe = getEntry(parent,child)
		
		if fe then
			error(path..": Directory exists")
		end
		fe = getFirstEmptyEntry()
		--construct a dir entry
		fe[1] = "dir"
		fe.name = child
		fe.dptr = 0xFFFF
		fe.next = 0xFFFF -- we are currently the last entry
		fe.prev = 0xFFFF
		fe.type = 2
		--get last file entry in directory
		local lfe = getLastEntry(parent)
		if lfe then
			lfe = fents[lfe]
			lfe.next = fe.index
			fe.prev = lfe.index
			writeFileEntry(lfe.index)
		else
			--we are the first in the parent
			parent.dptr = fe.index
			writeFileEntry(parent.index)
		end
		
		writeFileEntry(fe.index)
		return true
	end
	
	function fs.list(path)
		local pt = split_path(path)
		local child = table.remove(pt,#pt)
		local parent = traversePath(files,pt)
		local fe = child and getEntry(parent,child) or parent.index
		
		if not fe then
			error(path..": Directory does not exist")
		else
			fe = fents[fe]
		end
		if fe[1] ~= "dir" then
			error(path..": Not a directory")
		end
		local l = {}
		local cur = fe.dptr
		if cur == 0xFFFF then return l end
		while true do
			local f = fents[cur]
			l[#l+1] = f.name
			if f.next == 0xFFFF then break end
			cur = f.next
		end
		return l
	end
	
	function fs.lastModified() return 0 end --Pfft.
	
	function fs.exists(path)
		local pt = split_path(path)
		local child = table.remove(pt,#pt)
		local parent = traversePath(files,pt)
		local fe = getEntry(parent,child)
		print(path.." exists: "..tostring(fe ~= nil))
		return fe ~= nil
	end
	
	function fs.size(path)
		return #fs.readFromFile(path)
	end
	
	function fs.isDirectory(path)
		local pt = split_path(path)
		local child = table.remove(pt,#pt)
		local parent = traversePath(files,pt)
		local fe = getEntry(parent,child)
		
		if not fe then
			return false
		else
			fe = fents[fe]
		end
		return fe[1] == "dir"
	end
	
	function fs.open(file,mode)
		if mode == "r" or mode == "rb" then
			if not fs.exists(file) then return nil end
			return {file=file,data=fs.readFromFile(file),ptr=1,write=false}
		elseif mode == "w" or mode == "wb" then
			return {file=file,data="",ptr=1,write=true}
		elseif mode == "a" or mode == "ab" then
			if not fs.exists(file) then return nil end
			local r = {file=file,data=fs.readFromFile(file),write=true}
			r.ptr = #r.data
			return r
		end
	end
	
	function fs.read(handle,n)
		if handle.ptr > #handle.data then return nil end
		local nd = handle.data:sub(handle.ptr,n)
		handle.ptr = handle.ptr+n
		return nd
	end
	
	function fs.seek(handle, whence, offset)
		if whence == "set" then
			handle.ptr = math.min(math.max(offset+1,1),#handle.data)
		elseif whence == "end" then
			handle.ptr = #handle.data
		elseif whence == "cur" then
			handle.ptr = math.min(math.max(handle.ptr+offset,1),#handle.data)
		end
		return handle.ptr-1
	end
	
	function fs.write(handle,str)
		local dat = handle.data
		local pre = dat:sub(1,handle.ptr-1)
		local post = dat:sub(handle.ptr+#str)
		handle.data = pre..str..post
		handle.ptr = handle.ptr+#str
	end
	
	function fs.close(handle)
		if handle.write then
			fs.writeToFile(handle.file,handle.data)
		end
	end
	
	function fs.isReadOnly() return false end
	
	return fs
end

if _test then
	print("U")
	--test with fake disk drive
	local dat = ("\0"):rep(1024*1024)
	local sk = 1
	local td = {}
	function td.read(n)
		n = n or 1
		sk = sk+n
		return dat:sub(sk-n,sk-1)
	end
	
	function td.write(n)
		local pre = dat:sub(1,sk-1)
		local post = dat:sub(sk+#n)
		dat = pre..n..post
		sk = sk+#n
	end
	
	function td.seek(amt)
		if math.abs(amt) == math.huge then amt = (amt/math.abs(amt))*#dat end
		local pre = sk
		sk = math.max(math.min(sk+amt,#dat),1)
		return pre-sk
	end
	
	function td.getSize() return #dat end
	
	function td.saveToFile() local d = io.open("tape","w") d:write(dat) d:close() end
	
	td.address = "something"
	
	format(td)
	td.saveToFile()
	local fs = loadTDFS(td)
	fs.makeDirectory("dir")
	fs.writeToFile("dir/file.txt","I am random file data.")
	fs.writeToFile("file.txt","I am random file data.")
	fs.writeToFile("file","HI")
	print(fs.readFromFile("dir/file.txt"))
	td.saveToFile()
	fs.remove("dir/file.txt")
	fs.remove("dir")
	td.saveToFile()
else
	local function printHelp()
		print("Usage: tdfs [address (optional)] [function] [args]")
		print("Possible Functions:")
		print("format - Formats the selected tape drive")
		print("put [from] [to] - Copies a file from the computer and puts it on the tape")
		print("get [from] [to] - Copies a file from the tape and saves it to the computer")
	end

	local args = {...}
	if not args[1] then printHelp() return end
	local td = component.tape_drive
	if component.get(args[1]) then
		td = component.proxy(component.get(args[1]))
		table.remove(args,1)
	end
	if args[1] == "format" then
		format(td)
	elseif args[1] == "put" then
		local rfs = require "filesystem"
		print("Loading TDFS from tape...")
		local fs = loadTDFS(td,args[#args] == "verbose")
		local file = rfs.open(args[2],"rb")
		fs.writeToFile(args[3],file:read(rfs.size(args[2])))
		file:close()
	elseif args[1] == "get" then
		print("Loading TDFS from tape...")
		local fs = loadTDFS(td,args[#args] == "verbose")
		local file = io.open(args[3],"wb")
		file:write(fs.readFromFile(args[2]))
		file:close()
	elseif args[1] == "list" then
		print("Loading TDFS from tape...")
		local fs = loadTDFS(td,args[#args] == "verbose")
		for i, v in pairs(fs.list(args[2] or "")) do print(v) end
	elseif args[1] == "remove" then
		print("Loading TDFS from tape...")
		local fs = loadTDFS(td,args[#args] == "verbose")
		fs.remove(args[2])
	elseif args[1] == "mount" then
		local rfs = require "filesystem"
		print("Loading TDFS from tape...")
		local fs = loadTDFS(td,args[#args] == "verbose")
		rfs.mount(fs,args[2])
		print("Mounted "..td.address.." at "..args[2])
	else
		printHelp()
		return
	end
end
