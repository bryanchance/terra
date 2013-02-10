--io.write("loading terra lib...")


-- LINE COVERAGE INFORMATION, CLEANUP OR REMOVE
--[[
local converageloader = loadfile("coverageinfo.lua")
local linetable = converageloader and converageloader() or {}
function terra.dumplineinfo()
    local F = io.open("coverageinfo.lua","w")
    F:write("return {\n")
    for k,v in pairs(linetable) do
        F:write("["..k.."] = "..v..";\n")
    end
    F:write("}\n")
    F:close()
end

local function debughook(event)
    local info = debug.getinfo(2,"Sl")
    if info.short_src == "src/terralib.lua" then
        linetable[info.currentline] = linetable[info.currentline] or 0
        linetable[info.currentline] = linetable[info.currentline] + 1
    end
end
debug.sethook(debughook,"l")
]]

local ffi = require("ffi")

terra.isverbose = 0 --set by C api

local function dbprint(level,...) 
    if terra.isverbose >= level then
        print(...)
    end
end
local function dbprintraw(level,obj)
    if terra.isverbose >= level then
        obj:printraw()
    end
end

--debug wrapper around cdef function to print out all the things being defined
local oldcdef = ffi.cdef
ffi.cdef = function(...)
    dbprint(2,...)
    return oldcdef(...)
end

-- TREE
terra.tree = {} --metatype for trees
terra.tree.__index = terra.tree
function terra.tree:is(value)
    return self.kind == terra.kinds[value]
end
 
function terra.tree:printraw()
    local function header(key,t)
        if type(t) == "table" and (getmetatable(t) == nil or type(getmetatable(t).__index) ~= "function") then
            return terra.kinds[t["kind"]] or ""
        elseif (key == "type" or key == "operator") and type(t) == "number" then
            return terra.kinds[t] .. " (enum " .. tostring(t) .. ")"
        else
            return tostring(t)
        end
    end
    local function isList(t)
        return type(t) == "table" and #t ~= 0
    end
    local parents = {}
    local depth = 0
    local function printElem(t,spacing)
        if(type(t) == "table") then
            if parents[t] then
                print(string.rep(" ",#spacing).."<cyclic reference>")
                return
            elseif depth > 0 and (terra.isfunction(t) or terra.isfunctionvariant(t)) then
                return --don't print the entire nested function...
            end
            parents[t] = true
            depth = depth + 1
            for k,v in pairs(t) do
                if type(k) == "table" and not terra.issymbol(k) then
                    print("this table:")
                    terra.tree.printraw(k)
                    error("table is key?")
                end
                if k ~= "kind" and k ~= "offset" --[[and k ~= "linenumber"]] then
                    local prefix = spacing..tostring(k)..": "
                    if terra.types.istype(v) then --dont print the raw form of types unless printraw was called directly on the type
                        print(prefix..tostring(v))
                    else
                        print(prefix..header(k,v))
                        if isList(v) then
                            printElem(v,string.rep(" ",2+#spacing))
                        else
                            printElem(v,string.rep(" ",2+#prefix))
                        end
                    end
                end
            end
            depth = depth - 1
            parents[t] = nil
        end
    end
    print(header(nil,self))
    if type(self) == "table" then
        printElem(self,"  ")
    end
end

function terra.tree:copy(new_tree)
    if not new_tree then
        print(debug.traceback())
        error("empty tree?")
    end
    for k,v in pairs(self) do
        if not new_tree[k] then
            new_tree[k] = v
        end
    end
    return setmetatable(new_tree,getmetatable(self))
end

function terra.newtree(ref,body)
    if not ref or not terra.istree(ref) then
        terra.tree.printraw(ref)
        print(debug.traceback())
        error("not a tree?",2)
    end
    body.offset = ref.offset
    body.linenumber = ref.linenumber
    body.filename = ref.filename
    return setmetatable(body,terra.tree)
end

function terra.istree(v) 
    return terra.tree == getmetatable(v)
end

-- END TREE


-- LIST
terra.list = {} --used for all ast lists
setmetatable(terra.list,{ __index = table })
terra.list.__index = terra.list
function terra.newlist(lst)
    if lst == nil then
        lst = {}
    end
    return setmetatable(lst,terra.list)
end

function terra.list:map(fn)
    local l = terra.newlist()
    for i,v in ipairs(self) do
        l[i] = fn(v)
    end 
    return l
end
function terra.list:flatmap(fn)
    local l = terra.newlist()
    for i,v in ipairs(self) do
        local tmp = fn(v)
        if terra.islist(tmp) then
            for _,v2 in ipairs(tmp) do
                l:insert(v2)
            end
        else
            l:insert(tmp)
        end
    end 
    return l
end


function terra.list:printraw()
    for i,v in ipairs(self) do
        if v.printraw then
            print(i,v:printraw())
        else
            print(i,v)
        end
    end
end
function terra.list:mkstring(begin,sep,finish)
    if sep == nil then
        begin,sep,finish = "",begin,""
    end
    local len = #self
    if len == 0 then return begin..finish end
    local str = begin .. tostring(self[1])
    for i = 2,len do
        str = str .. sep .. tostring(self[i])
    end
    return str..finish
end

function terra.islist(exp)
    return getmetatable(exp) == terra.list
end

-- END LIST

-- CONTEXT
terra.context = {}
terra.context.__index = terra.context

function terra.iscontext(ctx)
    return getmetatable(ctx) == terra.context
end

function terra.context:isempty()
    return #self.functions == 0
end

function terra.context:functionbegin(func)
    func.compileindex = self.nextindex
    func.lowlink = func.compileindex
    self.nextindex = self.nextindex + 1
    
    table.insert(self.functions,func)
    table.insert(self.tobecompiled,func)
    
end

function terra.context:functionend()
    local func = table.remove(self.functions)
    local prev = self.functions[#self.functions]
    if prev ~= nil then
        prev.lowlink = math.min(prev.lowlink,func.lowlink)
    end
    
    if func.lowlink == func.compileindex then
        local scc = terra.newlist{}
        repeat
            local tocompile = table.remove(self.tobecompiled)
            scc:insert(tocompile)
        until tocompile == func
        
        if not self.diagnostics:haserrors() then
            terra.optimize({ functions = scc, flags = self.compileflags })
        end
        
        for i,f in ipairs(scc) do
            f.state = "optimize"
            if not self.diagnostics:haserrors() and not self.compileflags.nojit then
                f:jitandmakewrapper(self.compileflags)
            end
        end
        return true
    end
    return false
end

function terra.context:functioncalls(func)
    local curfunc = self.functions[#self.functions]
    if curfunc then
        curfunc.lowlink = math.min(curfunc.lowlink,func.compileindex)
    end
end

function terra.getcontext(flags)
    if not terra.globalcompilecontext then
        terra.globalcompilecontext = setmetatable({definitions = {}, diagnostics = terra.newdiagnostics() , functions = {}, tobecompiled = {}, nextindex = 0},terra.context)
    end
    terra.globalcompilecontext.compileflags = flags or {}
    return terra.globalcompilecontext
end

-- END CONTEXT

-- ENVIRONMENT

terra.environment = {}
terra.environment.__index = terra.environment

function terra.environment:enterblock()
    self._localenv = setmetatable({},{ __index = self._localenv })
end
function terra.environment:leaveblock()
    self._localenv = getmetatable(self._localenv).__index
end
function terra.environment:localenv()
    return self._localenv
end
function terra.environment:luaenv()
    return self._luaenv
end
function terra.environment:combinedenv()
    return self._combinedenv
end

function terra.newenvironment(_luaenv)
    local self = {}
    self._luaenv = _luaenv
    self._localenv = {}
    self._combinedenv = setmetatable({}, {
        __index = function(_,idx)
            return self._localenv[idx] or self._luaenv[idx]
        end;
        __newindex = function() 
            error("cannot define global variables in an escape")
        end;
    })
    return setmetatable(self, terra.environment)
end



-- END ENVIRONMENT


-- DIAGNOSTICS

terra.diagnostics = {}
terra.diagnostics.__index = terra.diagnostics

--terra.printlocation
--and terra.opensourcefile are inserted by C wrapper
function terra.diagnostics:printsource(anchor)
    local filename = anchor.filename
    local handle = self.filecache[filename] or terra.opensourcefile(filename)
    self.filecache[filename] = handle
    
    if handle then --if the code did not come from a file then we don't print the carrot, since we cannot (easily) find the text
        terra.printlocation(handle,anchor.offset)
    end
end

function terra.diagnostics:clearfilecache()
    for k,v in pairs(self.filecache) do
        terra.closesourcefile(v)
    end
    self.filecache = {}
end

function terra.diagnostics:reporterror(anchor,...)
    self._haserrors = true
    if not anchor then
        print(debug.traceback())
        error("nil anchor")
    end
    io.write(anchor.filename..":"..anchor.linenumber..": ")
    for _,v in ipairs({...}) do
        io.write(tostring(v))
    end
    io.write("\n")
    self:printsource(anchor)
end

function terra.diagnostics:haserrors()
    return self._haserrors
end

function terra.diagnostics:abortiferrors(msg)
    if self:haserrors() then
        self:clearfilecache()
        self._haserrors = false --clear error state so future calls don't abort
        error(msg)
    else
        assert(#self.filecache == 0)
    end
end

function terra.newdiagnostics()
    return setmetatable({ filecache = {}, _haserrors = false },terra.diagnostics)
end

-- END DIAGNOSTICS

-- FUNCVARIANT

-- a function variant is an implementation of a function for a particular set of arguments
-- functions themselves are overloadable. Each potential implementation is its own function variant
-- with its own compile state, type, AST, etc.
 
terra.funcvariant = {} --metatable for all function types
terra.funcvariant.__index = terra.funcvariant

function terra.funcvariant:hasbeeninstate(state)
    local states = {"uninitializedterra","uninitializedc","typecheck","codegen","optimize","initialized"}
    for i,s in ipairs(states) do
        if state == s then
            return true
        end
        if self.state == s then
            break
        end
    end
    return false
end
function terra.funcvariant:peektype() --look at the type but don't compile the function (if possible)
                                      --this will return success, <type if success == true>
    if self.type then
        return true,self.type
    end
    if not self.untypedtree.return_types then
        return false
    end

    local params = self.untypedtree.parameters:map(function(entry) return entry.type end)
    local rets   = self.untypedtree.return_types
    self.type = terra.types.functype(params,rets) --for future calls
    
    return true, self.type
end
function terra.funcvariant:gettype(ctx)
    if self.state == "codegen" then --function is in the same strongly connected component of the call graph as its called, even though it has already been typechecked
        ctx:functioncalls(self)
        assert(self.type ~= nil, "no type in codegen'd function?")
        return self.type
    elseif self.state == "typecheck" then
        ctx:functioncalls(self)
        local success,typ = self:peektype(ctx) --we are already compiling this function, but if the return types are listed, we can resolve the type anyway 
        if success then
            return typ
        else
            return terra.types.error, "recursively called function needs an explicit return type"
        end
    else
        self:compile(ctx)
        return self.type
    end    
end
function terra.funcvariant:makewrapper()
    local fntyp = self.type
    
    local success,cfntyp = pcall(fntyp.cstring,fntyp)
    
    if not success then
        dbprint(1,"cstring error: ",cfntyp)
        self.ffiwrapper = function()
            error("function not callable directly from lua")
        end
        return
    end
    
    self.ffiwrapper = ffi.cast(cfntyp,self.fptr)

end

function terra.funcvariant:jitandmakewrapper(flags)
    terra.jit({ func = self, flags = flags })
    self:makewrapper()
    self.state = "initialized"
end

function terra.funcvariant:compile(ctx)
    
    local freshcall = ctx == nil --was this a call to the compiler from within the compiler? or was it a fresh call to the compiler?
    if self.state == "initialized" then
        return
    end

    
    if self.state == "uninitializedc" then --this is a stub generated by the c wrapper, connect it with the right llvm_function object and set fptr
        terra.registercfunction(self)
        self:makewrapper()
        self.state = "initialized"
        return
    end
    
    local ctx = (terra.iscontext(ctx) and ctx) or terra.getcontext(ctx) -- if this is a top level compile, create a new compilation context
    
    if self.state == "optimize" then
        if ctx.compileflags.nojit or ctx.diagnostics:haserrors() then
            return
        end
        self:jitandmakewrapper(ctx.compileflags)
        return
    end
    

    if self.state ~= "uninitializedterra" then
        error("attempting to compile a function that is already in the process of being compiled.",2)
    end

    ctx:functionbegin(self)
    self.state = "typecheck"
    local start = terra.currenttimeinseconds()
    self.typedtree = self:typecheck(ctx)
    
    self.stats.typec = terra.currenttimeinseconds() - start
    self.type = self.typedtree.type
    
    self.state = "codegen"
    
    if not ctx.diagnostics:haserrors() then
        terra.codegen(self)
    end
    
    local compiled = ctx:functionend(self)

    if ctx:isempty() then --if this was not the top level compile we let type-checking of other functions continue, 
                          --though we don't actually compile because of the errors
        ctx.diagnostics:abortiferrors("Errors reported during compilation.")
    end

    if not compiled and freshcall then
        error("attempting to compile function within another function that requires it.",2)
    end
    
end

function terra.funcvariant:__call(...)
    self:compile()
    local NR = #self.type.returns
    if NR <= 1 then --fast path
        return self.ffiwrapper(...)
    else
        --multireturn
        local rs = self.ffiwrapper(...)
        local rl = {}
        for i = 0,NR-1 do
            table.insert(rl,rs["_"..i])
        end
        return unpack(rl)
    end
end

terra.llvm_gcdebugmetatable = { __gc = function(obj)
    print("GC IS CALLED")
end }

function terra.isfunctionvariant(obj)
    return getmetatable(obj) == terra.funcvariant
end

--END FUNCVARIANT

-- FUNCTION
-- a function is a list of possible function variants that can be invoked
-- it is implemented this way to support function overloading, where the same symbol
-- may have different variants

terra.func = {} --metatable for all function types
terra.func.__index = terra.func

function terra.func:compile(ctx)
    for i,v in ipairs(self.variants) do
        v:compile(ctx)
    end
end

function terra.func:__call(...)
    self:compile()
    if #self.variants == 1 then --fast path for the non-overloaded case
        return self.variants[1](...)
    end
    
    local results
    for i,v in ipairs(self.variants) do
        --TODO: this is very inefficient, we should have a routine which
        --figures out which function to call based on argument types
        results = {pcall(v.__call,v,...)}
        if results[1] == true then
            table.remove(results,1)
            return unpack(results)
        end
    end
    --none of the variants worked, remove the final error
    error(results[2])
end

function terra.func:addvariant(v)
    self.variants:insert(v)
end

function terra.func:getvariants()
    return self.variants
end

function terra.func:printstats()
    self:compile()
    for i,v in ipairs(self.variants) do
        print("variant ", v.type)
        for k,v in pairs(v.stats) do
            print("",k,v)
        end
    end
end

function terra.func:disas()
    self:compile()
    for i,v in ipairs(self.variants) do
        print("variant ", v.type)
        terra.disassemble(v)
    end
end

function terra.isfunction(obj)
    return getmetatable(obj) == terra.func
end

-- END FUNCTION

-- GLOBALVAR

terra.globalvar = {} --metatable for all global variables
terra.globalvar.__index = terra.globalvar

function terra.isglobalvar(obj)
    return getmetatable(obj) == terra.globalvar
end

function terra.globalvar:gettype()
    return self.type
end

--terra.createglobal provided by tcompiler.cpp
function terra.global(a0, a1)
    local typ,c
    if terra.types.istype(a0) then
        typ = a0
        if a1 then
            c = terra.constant(typ,a1)
        end
    else
        c = terra.constant(a0)
        typ = c.type
    end
    
    local gbl =  setmetatable({type = typ, isglobal = true, initializer = c},terra.globalvar)
    
    if c then --if we have an initializer we know that the type is not opaque and we can create the variable
              --we need to call this now because it is possible for the initializer's underlying cdata object to change value
              --in later code
        gbl:getpointer()
    end

    return gbl
end

function terra.globalvar:getpointer()
    if not self.llvm_ptr then
        self.type:freeze()
        terra.createglobal(self)
    end
    if not self.cdata_ptr then
        self.cdata_ptr = terra.cast(terra.types.pointer(self.type),self.llvm_ptr)
    end
    return self.cdata_ptr
end
function terra.globalvar:get()
    local ptr = self:getpointer()
    return ptr[0]
end
function terra.globalvar:set(v)
    local ptr = self:getpointer()
    ptr[0] = v
end
    

-- END GLOBALVAR

-- MACRO

terra.macro = {}
terra.macro.__index = terra.macro
terra.macro.__call = function(self,...)
    return self.fn(...)
end

function terra.ismacro(t)
    return getmetatable(t) == terra.macro
end

function terra.createmacro(fn)
    return setmetatable({fn = fn}, terra.macro)
end
_G["macro"] = terra.createmacro --introduce macro intrinsic into global namespace

-- END MACRO


function terra.israwlist(l)
    if terralib.islist(l) then
        return true
    elseif type(l) == "table" and not getmetatable(l) then
        local sz = #l
        local i = 0
        for k,v in pairs(l) do
            i = i + 1
        end
        return i == sz --table only has integer keys and no other keys, we treat it as a list
    end
    return false
end

-- QUOTE
terra.quote = {}
terra.quote.__index = terra.quote
function terra.isquote(t)
    return getmetatable(t) == terra.quote
end

function terra.quote:astype()
    local obj = (self.tree:is "typedexpressionlist" and self.tree.expressions[1]) or self.tree
    if not obj:is "luaobject" or not terra.types.istype(obj.value) then
        error("quoted value is not a type")
    end
    return obj.value
end

function terra.quote:asvalue()
    
    local function getvalue(e)
        if e:is "literal" then
            if type(e.value) == "userdata" then
                return tonumber(ffi.cast("uint64_t *",e.value)[0])
            else
                return e.value
            end
        elseif e:is "constant" then
            return tonumber(e.value.object) or e.value.object
        elseif e:is "constructor" then
            local t = {}
            for i,r in ipairs(e.records) do
                t[r.key] = getvalue(e.expressions.expressions[i])
            end
            return t
        elseif e:is "typedexpressionlist" then
            local e1 = e.expressions[1]
            return (e1 and getvalue(e1)) or {} 
        else
             error("the rest of :asvalue() needs to be implemented...")
        end
    end
    
    local v = getvalue(self.tree)
    
    return v
end
function terra.newquote(tree)
    return setmetatable({ tree = tree }, terra.quote)
end

-- END QUOTE

-- SYMBOL
terra.symbol = {}
terra.symbol.__index = terra.symbol
function terra.issymbol(s)
    return getmetatable(s) == terra.symbol
end
terra.symbol.count = 0

function terra.newsymbol(typ,displayname)
    if typ and not terra.types.istype(typ) then
        if type(typ) == "string" and displayname == nil then
            displayname = typ
            typ = nil
        else
            error("argument is not a type",2)
        end
    end
    local self = setmetatable({
        id = terra.symbol.count,
        type = typ,
        displayname = displayname
    },terra.symbol)
    terra.symbol.count = terra.symbol.count + 1
    return self
end

function terra.symbol:__tostring()
    return "$"..(self.displayname or tostring(self.id))
end

_G["symbol"] = terra.newsymbol 

-- INTRINSIC

function terra.intrinsic(str, typ)
    local typefn
    if typ == nil and type(str) == "function" then
        typefn = str
    elseif type(str) == "string" and terra.types.istype(typ) then
        typefn = function() return str,typ end
    else
        error("expected a name and type or a function providing a name and type but found "..tostring(str) .. ", " .. tostring(typ))
    end
    local function instrinsiccall(ctx,tree,...)
        local args = terra.newlist({...}):map(function(e) return e.tree end)
        return terra.newtree(tree, { kind = terra.kinds.intrinsic, typefn = typefn, arguments = args } )
    end
    return macro(instrinsiccall)
end
    

-- CONSTRUCTORS
do  --constructor functions for terra functions and variables
    local name_count = 0
    local function manglename(nm)
        local fixed = nm:gsub("[^A-Za-z0-9]","_") .. name_count --todo if a user writes terra foo, pass in the string "foo"
        name_count = name_count + 1
        return fixed
    end
    local function newfunctionvariant(newtree,name,env,reciever)
        local rawname = (name or newtree.filename.."_"..newtree.linenumber.."_")
        local fname = manglename(rawname)
        local obj = { untypedtree = newtree, filename = newtree.filename, name = fname, state = "uninitializedterra", stats = {} }
        local fn = setmetatable(obj,terra.funcvariant)
        
        --handle desugaring of methods defintions by adding an implicit self argument
        if reciever ~= nil then
            local pointerto = terra.types.pointer
            local addressof = terra.newtree(newtree, { kind = terra.kinds.luaexpression, expression = function() return pointerto(reciever) end })
            local sym = terra.newtree(newtree, { kind = terra.kinds.symbol, name = "self"})
            local implicitparam = terra.newtree(newtree, { kind = terra.kinds.entry, name = sym, type = addressof })
            
            --add the implicit parameter to the parameter list
            local newparameters = terra.newlist{implicitparam}
            for _,p in ipairs(newtree.parameters) do
                newparameters:insert(p)
            end
            fn.untypedtree = newtree:copy { parameters = newparameters} 
        end

        fn.untypedtree = terra.specialize(fn.untypedtree,env)
        
        return fn
    end
    
    local function mkfunction(name)
        return setmetatable({variants = terra.newlist(), name = name},terra.func)
    end
    
    local function layoutstruct(st,tree,env)
        local diag = terra.newdiagnostics()

        if st.tree then
            diag:reporterror(tree,"attempting to redefine struct")
            diag:reporterror(st.tree,"previous definition was here")
        end

        local function addstructentry(v)
            local success,resolvedtype = terra.evalluaexpression(diag,env,v.type)
            if not success then return end
            if not terra.types.istype(resolvedtype) then
                diag:reporterror(v,"lua expression is not a terra type but ", type(resolvedtype))
                return
            end
            if not st:addentry(v.key,resolvedtype) then
                diag:reporterror(v,"duplicate definition of field ",v.key)
            end
        end
        
        local function addrecords(records)
            for i,v in ipairs(records) do
                if v.kind == terra.kinds["union"] then
                    st:beginunion()
                    addrecords(v.records)
                    st:endunion()
                else
                    addstructentry(v)
                end
            end
        end
        addrecords(tree.records)
        
        st.tree = tree --for debugging purposes and to track whether the struct has already beend defined
                       --we keep the tree to improve error reporting
        
        diag:abortiferrors("Errors reported during struct definition.")

    end

    local function declareobjects(N,declfn,...)
        local idx,args,results = 1,{...},{}
        for i = 1,N do
            local origv,name = args[idx], args[idx+1]
            results[i] = declfn(origv,name)
        end
        return unpack(results)
    end
    function terra.declarestructs(N,...)
        return declareobjects(N,function(origv,name)
            return (terra.types.istype(origv) and origv:isstruct() and origv) or terra.types.newstruct(name)
        end,...)
    end
    function terra.declarefunctions(N,...)
        return declareobjects(N,function(origv,name)
            return (terra.isfunction(origv) and origv) or mkfunction(name)
        end,...)
    end

    function terra.defineobjects(fmt,envfn,...)
        local args = {...}
        local idx = 1
        local results = {}
        for i = 1, #fmt do
            local c = fmt:sub(i,i)
            local obj, name, tree = args[idx], args[idx+1], args[idx+2]
            idx = idx + 3
            if "s" == c then
                layoutstruct(obj,tree,envfn())
            elseif "f" == c or "m" == c then
                local reciever = nil
                if "m" == c then
                    reciever = args[idx]
                    idx = idx + 1
                end
                obj:addvariant(newfunctionvariant(tree,name,envfn(),reciever))
            else
                error("unknown object format: "..c)
            end
        end
    end

    function terra.anonstruct(tree,envfn)
        local st = terra.types.newstruct("anon")
        layoutstruct(st,tree,envfn())
        st:setconvertible(true)
        return st
    end

    function terra.anonfunction(tree,envfn)
        local fn = mkfunction(nil)
        fn:addvariant(newfunctionvariant(tree,nil,envfn(),nil))
        return fn
    end

    function terra.newcfunction(name,typ)
        local obj = { name = name, type = typ, state = "uninitializedc" }
        setmetatable(obj,terra.funcvariant)
        
        local fn = mkfunction(name)
        fn:addvariant(obj)
        
        return fn
    end

    function terra.definequote(tree,envfn)
        return terra.newquote(terra.specialize(tree,envfn()))
    end
end

-- END CONSTRUCTORS

-- TYPE

do --construct type table that holds the singleton value representing each unique type
   --eventually this will be linked to the LLVM object representing the type
   --and any information about the operators defined on the type
    local types = {}
    
    
    types.type = {} --all types have this as their metatable
    types.type.__index = function(self,key)
        local N = tonumber(key)
        if N then
            return types.array(self,N) -- int[3] should create an array
        else
            return types.type[key]  -- int:ispointer() (which translates to int["ispointer"](self)) should look up ispointer in types.type
        end
    end
    
    
    function types.type:__tostring()
        return self.displayname or self.name
    end
    types.type.printraw = terra.tree.printraw
    function types.type:isprimitive()
        return self.kind == terra.kinds.primitive
    end
    function types.type:isintegral()
        return self.kind == terra.kinds.primitive and self.type == terra.kinds.integer
    end
    function types.type:isfloat()
        return self.kind == terra.kinds.primitive and self.type == terra.kinds.float
    end
    function types.type:isarithmetic()
        return self.kind == terra.kinds.primitive and (self.type == terra.kinds.integer or self.type == terra.kinds.float)
    end
    function types.type:islogical()
        return self.kind == terra.kinds.primitive and self.type == terra.kinds.logical
    end
    function types.type:canbeord()
        return self:isintegral() or self:islogical()
    end
    function types.type:ispointer()
        return self.kind == terra.kinds.pointer
    end
    function types.type:isarray()
        return self.kind == terra.kinds.array
    end
    function types.type:isfunction()
        return self.kind == terra.kinds.functype
    end
    function types.type:isstruct()
        return self.kind == terra.kinds["struct"]
    end
    function types.type:ispointertostruct()
        return self:ispointer() and self.type:isstruct()
    end
    function types.type:ispointertofunction()
        return self:ispointer() and self.type:isfunction()
    end
    function types.type:isaggregate() 
        return self:isstruct() or self:isarray()
    end
    
    function types.type:iscanonical()
        return not self:isstruct() or not self.incomplete
    end
    
    function types.type:isvector()
        return self.kind == terra.kinds.vector
    end
    
    local applies_to_vectors = {"isprimitive","isintegral","isarithmetic","islogical", "canbeord"}
    for i,n in ipairs(applies_to_vectors) do
        types.type[n.."orvector"] = function(self)
            return self[n](self) or (self:isvector() and self.type[n](self.type))  
        end
    end
    
    local next_type_id = 0 --used to generate uniq type names
    local function uniquetypename(base,name) --used to generate unique typedefs for C
        local r = base.."_"
        if name then
            r = r..name.."_"
        end
        r = r..next_type_id
        next_type_id = next_type_id + 1
        return r
    end
    
    function types.type:cstring()
        if not self.cachedcstring then
            
            local function definetype(base,name,value)
                local nm = uniquetypename(base,name)
                ffi.cdef("typedef "..value.." "..nm..";")
                return nm
            end
            
            --assumption: cachedcstring needs to be an identifier, it cannot be a derived type (e.g. int*)
            --this makes it possible to predict the syntax of subsequent typedef operations
            if self:isintegral() then
                self.cachedcstring = tostring(self).."_t"
            elseif self:isfloat() then
                self.cachedcstring = tostring(self)
            elseif self:ispointer() and self.type:isfunction() then --function pointers and functions have the same typedef
                self.cachedcstring = self.type:cstring()
            elseif self:ispointer() then
                local value = self.type:cstring()
                if not self.cachedcstring then --if this type was recursive then it might have created the value already   
                    self.cachedcstring = definetype(value,"ptr",value .. "*")
                end
            elseif self:islogical() then
                self.cachedcstring = "uint8_t"
            elseif self:isstruct() then
                local nm = uniquetypename(self.name)
                ffi.cdef("typedef struct "..nm.." "..nm..";") --first make a typedef to the opaque pointer
                self.cachedcstring = nm -- prevent recursive structs from re-entering this function by having them return the name
                local str = "struct "..nm.." { "
                for i,v in ipairs(self.entries) do
                
                    local prevalloc = self.entries[i-1] and self.entries[i-1].allocation
                    local nextalloc = self.entries[i+1] and self.entries[i+1].allocation
            
                    if v.inunion and prevalloc ~= v.allocation then
                        str = str .. " union { "
                    end
                    
                    local keystr = v.key
                    if terra.issymbol(keystr) then
                        keystr = "__symbol"..tostring(keystr.id)
                    end
                    str = str..v.type:cstring().." "..keystr.."; "
                    
                    if v.inunion and nextalloc ~= v.allocation then
                        str = str .. " }; "
                    end
                    
                end
                str = str .. "};"
                ffi.cdef(str)
            elseif self:isarray() then
                local value = self.type:cstring()
                if not self.cachedcstring then
                    local nm = uniquetypename(value,"arr")
                    ffi.cdef("typedef "..value.." "..nm.."["..tostring(self.N).."];")
                    self.cachedcstring = nm
                end
            elseif self:isfunction() then
                local rt = (#self.returns == 0 and "void") or self.returnobj:cstring()
                local function getcstring(t)
                    if t == rawstring then
                        --hack to make it possible to pass strings to terra functions
                        --this breaks some lesser used functionality (e.g. passing and mutating &int8 pointers)
                        --so it should be removed when we have a better solution
                        return "const char *"
                    else
                        return t:cstring()
                    end
                end
                local pa = self.parameters:map(getcstring)
                pa = pa:mkstring("(",",",")")
                local ntyp = uniquetypename("function")
                local cdef = "typedef "..rt.." (*"..ntyp..")"..pa..";"
                ffi.cdef(cdef)
                self.cachedcstring = ntyp
            elseif self == types.niltype then
                local nilname = uniquetypename("niltype")
                ffi.cdef("typedef void * "..nilname..";")
                self.cachedcstring = nilname
            elseif self == types.error then
                self.cachedcstring = "int"
            else
                error("NYI - cstring")
            end    
        end
        if not self.cachedcstring then error("cstring not set? "..tostring(self)) end
        
        --create a map from this ctype to the terra type to that we can implement terra.typeof(cdata)
        local ctype = ffi.typeof(self.cachedcstring)
        types.ctypetoterra[tostring(ctype)] = self
        local rctype = ffi.typeof(self.cachedcstring.."&")
        types.ctypetoterra[tostring(rctype)] = self

        return self.cachedcstring
    end
    
    function types.type:freeze(diag) --overriden by named structs to build their member tables and by proxy types to lazily evaluate their type
        if not self.complete then
            self.complete = true
            if self:isvector() or self:ispointer() or self:isarray() then
                self.type:freeze(diag)
            elseif self:isfunction() then
                self.parameters:map(function(e) e:freeze(diag) end)
                self.returns   :map(function(e) e:freeze(diag) end)
            end
        end
        return self
    end
        
    function types.istype(t)
        return getmetatable(t) == types.type
    end
    
    --map from unique type identifier string to the metadata for the type
    types.table = {}
    
    --map from luajit ffi ctype objects to corresponding terra type
    types.ctypetoterra = {}
    
    local function mktyp(v)
        v.methods = {}
        return setmetatable(v,types.type)
    end
    
    local function registertype(name, constructor)
        local typ = types.table[name]
        if typ == nil then
            if types.istype(constructor) then
                typ = constructor
            elseif type(constructor) == "function" then
                typ = constructor()
            else
                error("expected function or type")
            end
            typ.name = name
            types.table[name] = typ
        end
        return typ
    end
    
    --initialize integral types
    local integer_sizes = {1,2,4,8}
    for _,size in ipairs(integer_sizes) do
        for _,s in ipairs{true,false} do
            local name = "int"..tostring(size * 8)
            if not s then
                name = "u"..name
            end
            registertype(name,
                         mktyp { kind = terra.kinds.primitive, bytes = size, type = terra.kinds.integer, signed = s})
        end
    end  
    
    registertype("float", mktyp { kind = terra.kinds.primitive, bytes = 4, type = terra.kinds.float })
    registertype("double",mktyp { kind = terra.kinds.primitive, bytes = 8, type = terra.kinds.float })
    registertype("bool",  mktyp { kind = terra.kinds.primitive, bytes = 1, type = terra.kinds.logical})
    
    types.error   = registertype("error",  mktyp { kind = terra.kinds.error })
    types.niltype = registertype("niltype",mktyp { kind = terra.kinds.niltype}) -- the type of the singleton nil (implicitly convertable to any pointer type)
    
    local function checkistype(typ)
        if not types.istype(typ) then 
            error("expected a type but found "..type(typ))
        end
    end
    
    function types.pointer(typ)
        checkistype(typ)
        if typ == types.error then return types.error end
        
        return registertype("&"..typ.name, function()
            return mktyp { kind = terra.kinds.pointer, type = typ }
        end)
    end
    
    local function checkarraylike(typ, N_)
        local N = tonumber(N_)
        checkistype(typ)
        if not N then
            error("expected a number but found "..type(N_))
        end
        return N
    end
    
    function types.array(typ, N_)
        local N = checkarraylike(typ,N_)
        if typ == types.error then return types.error end
        
        local tname = (typ:ispointer() and "("..typ.name..")") or typ.name
        local name = tname .. "[" .. N .. "]"
        return registertype(name,function()
            return mktyp { kind = terra.kinds.array, type = typ, N = N }
        end)
    end
    
    function types.vector(typ,N_)
        local N = checkarraylike(typ,N_)
        if typ == types.error then return types.error end
        
        
        if not typ:isprimitive() then
            error("vectors must be composed of primitive types (for now...) but found type "..tostring(typ))
        end
        local name = "vector("..typ.name..","..N..")"
        return registertype(name,function()
            return mktyp { kind = terra.kinds.vector, type = typ, N = N }
        end)
    end
    
    function types.primitive(name)
        return types.table[name] or types.error
    end
    
    
    local definedstructs = {}
    local function getuniquestructname(displayname)
        local name = displayname
        if definedstructs[displayname] then 
            name = name .. tostring(definedstructs[displayname])
        else
            definedstructs[displayname] = 0
        end
        definedstructs[displayname] = definedstructs[displayname] + 1
        return name
    end
    
    function types.newstruct(displayname)
        if not displayname then
            displayname = "anon"
        end
        assert(displayname ~= "")
        local name = getuniquestructname(displayname)
                
        local tbl = mktyp { kind = terra.kinds["struct"],
                            name = name, 
                            displayname = displayname, 
                            entries = terra.newlist(), 
                            keytoindex = {}, 
                            nextunnamed = 0, 
                            nextallocation = 0,
                            layoutfunctions = terra.newlist(),                           
                          }
                            
        function tbl:addentry(k,t)
            assert(not self.complete)
            local entry = { type = t, key = k, hasname = true, allocation = self.nextallocation, inunion = self.inunion ~= nil }
            if not k then
                entry.hasname = false
                entry.key = "_"..tostring(self.nextunnamed)
                self.nextunnamed = self.nextunnamed + 1
            end
            
            local notduplicate = self.keytoindex[entry.key] == nil          
            self.keytoindex[entry.key] = #self.entries
            self.entries:insert(entry)
            
            if self.inunion then
                self.unionisnonempty = true
            else
                self.nextallocation = self.nextallocation + 1
            end
            
            return notduplicate
        end
        function tbl:beginunion()
            assert(not self.complete)
            if not self.inunion then
                self.inunion = 0
            end
            self.inunion = self.inunion + 1
        end
        function tbl:endunion()
            assert(not self.complete)
            self.inunion = self.inunion - 1
            if self.inunion == 0 then
                self.inunion = nil
                if self.unionisnonempty then
                    self.nextallocation = self.nextallocation + 1
                end
                self.unionisnonempty = nil
            end
        end
        
        
        function tbl:freeze(diag)
        
            assert(not self.complete)
            self.complete = true
            self.freeze = nil -- if we recursively try to evaluate this type then just return it
            
            --TODO: this is where a metatable callback will occur right before the struct will become complete

            local ldiag = diag or terra.newdiagnostics()

            local function checkrecursion(t)
                if t == self then
                    if self.tree then
                        ldiag:reporterror(self.tree,"type recursively contains itself")
                    else
                        --TODO: emit where the user-defined type was first used
                        error("programmatically defined type contains itself")
                    end
                elseif t:isstruct() then
                    for i,v in ipairs(t.entries) do
                        checkrecursion(v.type)
                    end
                elseif t:isarray() or t:isvector() then
                    checkrecursion(t.type)
                end
            end
            for i,v in ipairs(self.entries) do
                v.type:freeze(diag)
                checkrecursion(v.type)
            end
            
            if not diag then
                ldiag:abortiferrors("Errors occured duing struct creation.")
            end

            dbprint(2,"Resolved Named Struct To:")
            dbprintraw(2,self)
            return self
        
        end
        
        function tbl:setconvertible(b)
            assert(not self.complete)
            self.isconvertible = b
        end
        
        return tbl
    end
    
    function types.funcpointer(parameters,returns,isvararg)
        if types.istype(parameters) then
            parameters = {parameters}
        end
        if types.istype(returns) then
            returns = {returns}
        end
        return types.pointer(types.functype(parameters,returns,isvararg))
    end
    
    function types.functype(parameters,returns,isvararg)
        
        if not terra.islist(parameters) then
            parameters = terra.newlist(parameters)
        end
        if not terra.islist(returns) then
            returns = terra.newlist(returns)
        end
        
        local function checkalltypes(l)
            for i,v in ipairs(l) do
                checkistype(v)
            end
        end
        checkalltypes(parameters)
        checkalltypes(returns)
        
        local function getname(t) return t.name end
        local a = terra.list.map(parameters,getname):mkstring("{",",","")
        if isvararg then
            a = a .. ",...}"
        else
            a = a .. "}"
        end
        local r = terra.list.map(returns,getname):mkstring("{",",","}")
        local name = a.."->"..r
        return registertype(name,function()
            local returnobj = nil
            if #returns == 1 then
                returnobj = returns[1]
            elseif #returns > 1 then
                returnobj = types.newstruct()
                for i,r in ipairs(returns) do
                    returnobj:addentry(nil,r)
                end
            end
            return mktyp { kind = terra.kinds.functype, parameters = parameters, returns = returns, isvararg = isvararg, returnobj = returnobj }
        end)
    end
    
    for name,typ in pairs(types.table) do
        --introduce primitive types into global namespace
        -- outside of the typechecker and internal terra modules
        if typ:isprimitive() then
            _G[name] = typ
        end 
    end
    _G["int"] = int32
    _G["uint"] = uint32
    _G["long"] = int64
    _G["intptr"] = uint64
    _G["ptrdiff"] = int64
    _G["niltype"] = types.niltype
    _G["rawstring"] = types.pointer(int8)
    terra.types = types
end

-- END TYPE

-- SPECIALIZATION (removal of escape expressions, escape sugar, evaluation of type expressoins)

--convert a lua value 'v' into the terra tree representing that value
function terra.createterraexpression(diag,anchor,v)
    local function createsingle(v)
        if terra.isglobalvar(v) or terra.issymbol(v) then
            local name = anchor:is "var" and anchor.name and tostring(anchor.name) --propage original variable name for debugging purposes
            return terra.newtree(anchor, { kind = terra.kinds["var"], value = v, name = name or tostring(v), lvalue = true }) 
        elseif terra.isquote(v) then
            assert(terra.istree(v.tree))
            if v.tree:is "block" then
                return terra.newtree(anchor, { kind = terra.kinds.treelist, values = v.tree.statements })
            else
                return v.tree
            end
        elseif terra.istree(v) then
            --if this is a raw tree, we just drop it in place and hope the user knew what they were doing
            return v
        elseif type(v) == "cdata" or type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            return createsingle(terra.constant(v))
        elseif terra.isconstant(v) then
            if type(v.object) == "string" then --strings are handled specially since they are a pointer type (rawstring) but the constant is actually string data, not just the pointer
                return terra.newtree(anchor, { kind = terra.kinds.literal, value = v.object, type = rawstring })
            else 
                return terra.newtree(anchor, { kind = terra.kinds.constant, value = v, type = v.type, lvalue = v.type:isaggregate()})
            end
        else
            if not (terra.isfunction(v) or terra.ismacro(v) or terra.types.istype(v) or type(v) == "function" or type(v) == "table") then
                diag:reporterror(anchor,"lua object of type ", type(v), " not understood by terra code.")
            end
            return terra.newtree(anchor, { kind = terra.kinds.luaobject, value = v })
        end
    end
    if terra.israwlist(v) then
        local values = terra.newlist()
        for _,i in ipairs(v) do
            values:insert(createsingle(i))
        end
        return terra.newtree(anchor, { kind = terra.kinds.treelist, values = values})
    else
        return createsingle(v)
    end
end

function terra.specialize(origtree, luaenv)
    local env = terra.newenvironment(luaenv)
    local diag = terra.newdiagnostics()

    local translatetree, translategenerictree, translatelist, resolvetype, createformalparameterlist, desugarfornum
    function translatetree(e)
        if e:is "var" then
            local v = env:combinedenv()[e.name]
            if v == nil then
                diag:reporterror(e,"variable '"..e.name.."' not found")
                return e
            end
            return terra.createterraexpression(diag,e,v)
        elseif e:is "select" then
            local ee = translategenerictree(e)
            if not ee.value:is "luaobject" then
                return ee
            end
            --note: luaobject only appear due to tree translation, so we can safely mutate ee
            local value,field = ee.value.value, ee.field
            if type(value) ~= "table" then
                diag:reporterror(e,"expected a table but found ", type(value))
                return ee
            end
            

            if terra.types.istype(value) then --class method resolve to method table
                value = value.methods
            end

            local selected = value[field]
            if selected == nil then
                diag:reporterror(e,"no field ", field," in lua object")
                return ee
            end
            return terra.createterraexpression(diag,e,selected)
        elseif e:is "luaexpression" then     
            local success, value = terra.evalluaexpression(diag,env:combinedenv(),e)
            return terra.createterraexpression(diag, e, (success and value) or {})
        elseif e:is "symbol" then
            local v
            if e.name then
                v = e.name
            else
                local success, r = terra.evalluaexpression(diag,env:combinedenv(),e.expression)
                if not success then 
                    v = terra.newsymbol(nil,"error")
                elseif type(r) ~= "string" and not terra.issymbol(r) then
                    diag:reporterror(e,"expected a string or symbol but found ",type(r))
                    v = terra.newsymbol(nil,"error")
                else
                    v = r
                end
            end
            return v
        elseif e:is "defvar" then
            local initializers = e.initializers and translatelist(e.initializers)
            local variables = createformalparameterlist(e.variables, initializers == nil)     
            return e:copy { variables = variables, initializers = initializers }
        elseif e:is "function" then
            local parameters = createformalparameterlist(e.parameters,true)
            local return_types
            if e.return_types then
                local success, value = terra.evalluaexpression(diag,env:combinedenv(),e.return_types)
                if success then
                    return_types = (terra.israwlist(value) and terra.newlist(value)) or terra.newlist { value }
                    for i,t in ipairs(return_types) do
                        if not terra.types.istype(t) then
                            diag:reporterror(e.return_types,"expected a type but found ",type(t))
                        end
                    end
                end
            end
            local body = translatetree(e.body)
            return e:copy { parameters = parameters, return_types = return_types, body = body }
        elseif e:is "fornum" then
            --we desugar this early on so that we don't have to have special handling for the definitions/scoping
            return translatetree(desugarfornum(e))
        elseif e:is "repeat" then
            --special handling of scope for
            env:enterblock()
            local b = translategenerictree(e.body)
            local c = translatetree(e.condition)
            env:leaveblock()
            if b ~= e.body or c ~= e.condition then
                return e:copy { body = b, condition = c }
            else
                return e
            end
        elseif e:is "block" then
            env:enterblock()
            local r = translategenerictree(e)
            env:leaveblock()
            return r
        else
            return translategenerictree(e)
        end
    end
    function createformalparameterlist(paramlist, requiretypes)
        local result = terra.newlist()
        for i,p in ipairs(paramlist) do
            if i ~= #paramlist or p.type or p.name.name then
                --treat the entry as a _single_ parameter if any are true:
                --if it is not the last entry in the list
                --it has an explicit type
                --it is a string (and hence cannot be multiple items) then
            
                local typ
                if p.type then
                    local success, v = terra.evalluaexpression(diag,env:combinedenv(),p.type)
                    typ = (success and v) or terra.types.error
                    if not terra.types.istype(typ) then
                        diag:reporterror(p,"expected a type but found ",type(typ))
                        typ = terra.types.error
                    end
                end
                local function registername(name,sym)
                    local lenv = env:localenv()
                    if rawget(lenv,name) then
                        diag:reporterror(p,"duplicate definition of variable ",name)
                    end
                    lenv[name] = sym
                end
                local symorstring = translatetree(p.name)
                local sym,name
                if type(symorstring) == "string" then
                    name = symorstring
                    if p.name.expression then
                        --in statement: "var [a] : int = ..." don't let 'a' resolve to a string 
                        diag:reporterror(p,"expected a symbol but found string")
                    else
                        --generate a new unique symbol for this variable and add it to the environment
                        --this will allow quotes to see it hygientically and references to it to be resolved to the symbol
                        local name = symorstring
                        local lenv = env:localenv()
                        sym = terra.newsymbol(nil,name)
                        registername(name,sym)
                    end
                else
                    sym = symorstring
                    name = tostring(sym)
                    registername(sym,sym)
                end
                result:insert(p:copy { type = typ, name = name, symbol = sym })
            else
                local sym = p.name
                assert(sym.expression)
                local success, value = terra.evalluaexpression(diag,env:combinedenv(),sym.expression)
                if success then
                    local symlist = (terra.israwlist(value) and value) or terra.newlist{ value }
                    for i,entry in ipairs(symlist) do
                        if terra.issymbol(entry) then
                            result:insert(p:copy { symbol = entry, name = tostring(entry) })
                        else
                            diag:reporterror(p,"expected a symbol but found ",type(entry))
                        end
                    end
                end
            end
        end
        for i,entry in ipairs(result) do
            local sym = entry.symbol
            entry.type = entry.type or sym.type --if the symbol was given a type but the parameter didn't have one
                                                --it takes the type of the symbol
            assert(entry.type == nil or terra.types.istype(entry.type))
            if requiretypes and not entry.type then
                diag:reporterror(entry,"type must be specified for parameters and uninitialized variables")
            end
        end
        return result
    end
    function desugarfornum(s)
        local function mkdefs(...)
            local lst = terra.newlist()
            for i,v in pairs({...}) do
                local sym = terra.newtree(s,{ kind = terra.kinds.symbol, name = v})
                lst:insert( terra.newtree(s,{ kind = terra.kinds.entry, name = sym }) )
            end
            return lst
        end
        
        local function mkvar(a)
            assert(type(a) == "string")
            return terra.newtree(s,{ kind = terra.kinds["var"], name = a })
        end
        
        local function mkop(op,a,b)
           return terra.newtree(s, {
            kind = terra.kinds.operator;
            operator = terra.kinds[op];
            operands = terra.newlist { mkvar(a), mkvar(b) };
            })
        end

        local dv = terra.newtree(s, { 
            kind = terra.kinds.defvar;
            variables = mkdefs("<i>","<limit>","<step>");
            initializers = terra.newlist({s.initial,s.limit,s.step})
        })
        
        local lt = mkop("<","<i>","<limit>")
        
        local newstmts = terra.newlist()

        local newvaras = terra.newtree(s, { 
            kind = terra.kinds.defvar;
            variables = terra.newlist{ terra.newtree(s, { kind = terra.kinds.entry, name = s.varname }) };
            initializers = terra.newlist{mkvar("<i>")}
        })
        newstmts:insert(newvaras)
        for _,v in pairs(s.body.statements) do
            newstmts:insert(v)
        end
        
        local p1 = mkop("+","<i>","<step>")
        local as = terra.newtree(s, {
            kind = terra.kinds.assignment;
            lhs = terra.newlist({mkvar("<i>")});
            rhs = terra.newlist({p1});
        })
        
        newstmts:insert(as)
        
        local nbody = terra.newtree(s, {
            kind = terra.kinds.block;
            statements = newstmts;
        })
        
        local wh = terra.newtree(s, {
            kind = terra.kinds["while"];
            condition = lt;
            body = nbody;
        })
    
        return terra.newtree(s, { kind = terra.kinds.block, statements = terra.newlist {dv,wh} } )
    end
    --recursively translate any tree or list of trees.
    --new objects are only created when we find a new value
    function translategenerictree(tree)
        assert(terra.istree(tree))
        local nt = nil
        local function addentry(k,origv,newv)
            if origv ~= newv then
                if not nt then
                    nt = tree:copy {}
                end
                nt[k] = newv
            end
        end
        for k,v in pairs(tree) do
            if terra.istree(v) then
                addentry(k,v,translatetree(v))
            elseif terra.islist(v) and #v > 0 and terra.istree(v[1]) then
                addentry(k,v,translatelist(v))
            end 
        end
        return nt or tree
    end
    function translatelist(lst)
        local changed = false
        local nl = lst:map(function(e)
            assert(terra.istree(e)) 
            local ee = translatetree(e)
            changed = changed or ee ~= e
            return ee
        end)
        return (changed and nl) or lst
    end
    
    dbprint(2,"specializing tree")
    dbprintraw(2,origtree)

    local newtree = translatetree(origtree)
    
    diag:abortiferrors("Errors reported during specialization.")
    return newtree
end

-- TYPECHECKER
function terra.reporterror(ctx,anchor,...)
    ctx.diagnostics:reporterror(anchor,...)
    return terra.types.error
end

function terra.evalluaexpression(diag, env, e)
    local function parseerrormessage(startline, errmsg)
        local line,err = errmsg:match [["$terra$"]:([0-9]+):(.*)]]
        if line and err then
            return startline + tonumber(line) - 1, "error evaluating lua code: " .. err
        else
            return startline, "error evaluating lua code: " .. errmsg
        end
    end
    if not terra.istree(e) or not e:is "luaexpression" then
       print(debug.traceback())
       terra.tree.printraw(e)
       error("not a lua expression?") 
    end
    assert(type(e.expression) == "function")
    local fn = e.expression
    setfenv(fn,env)
    local success,v = pcall(fn)
    if not success then --v contains the error message
        local ln,err = parseerrormessage(e.linenumber,v)
        diag:reporterror(e:copy( { linenumber = ln }),err)
        return false
    end
    return true,v
end

local function map(lst,fn)
    r = {}
    for i,v in ipairs(lst) do
        r[i] = fn(v)
    end
    return r
end

function terra.funcvariant:typecheck(ctx)
    
    --initialization

    dbprint(2,"compiling function:")
    dbprintraw(2,self.untypedtree)

    local ftree = self.untypedtree
    
    local symbolenv = terra.newenvironment()
    local diag = ctx.diagnostics

    -- TYPECHECKING FUNCTION DECLARATIONS
    --declarations major driver functions for typechecker
    local checkexp -- (e.g. 3 + 4)
    local checkstmt -- (e.g. var a = 3)
    local checkcall -- any invocation (method, function call, macro, overloaded operator) gets translated into a call to checkcall (e.g. sizeof(int), foobar(3), obj:method(arg))
    local checkparameterlist -- (e.g. 3,4 of foo(3,4))

    --helper functions interacting with state outside the typechecker
    local function invokeuserfunction(anchor, speculate, userfn,  ...)
        local results = { pcall(userfn, ...) }
        if not speculate and not results[1] then
            diag:reporterror(anchor,"error while invoking macro or metamethod: ",results[2])
        end
        return unpack(results)
    end

    --tree constructors for trees created in the typechecking process
    local function createcast(exp,typ)
        return terra.newtree(exp, { kind = terra.kinds.cast, from = exp.type, to = typ, type = typ, expression = exp })
    end
    local typedexpressionkey = {} --unique for this call to typecheck
    local function createtypedexpressionlist(anchor, explist, fncall, minsize)
        assert(terra.islist(explist))
        return terra.newtree(anchor, { kind = terra.kinds.typedexpressionlist, expressions = explist, fncall = fncall, key = typedexpressionkey, minsize = minsize or 0})
    end
    local function createextractreturn(anchor, index, t)
        return terra.newtree(anchor,{ kind = terra.kinds.extractreturn, index = index, type = t})
    end
    local function createfunctionliteral(anchor,e)
        local fntyp,errstr = e:gettype(ctx)
        if fntyp == terra.types.error then
            terra.reporterror(ctx,anchor,"error resolving function literal. ",errstr)
        end
        local typ = fntyp and terra.types.pointer(fntyp):freeze(diag)
        return terra.newtree(anchor, { kind = terra.kinds.literal, value = e, type = typ or terra.types.error })
    end
    

    local function asrvalue(ee)
        if ee.lvalue then
            return terra.newtree(ee,{ kind = terra.kinds.ltor, type = ee.type, expression = ee })
        else
            return ee
        end
    end
    local function aslvalue(ee) --this is used in a few cases where we allow rvalues to become lvalues
                          -- int[4] -> int * conversion, and invoking a method that requires a pointer on an rvalue
        if not ee.lvalue then
            if ee.kind == terra.kinds.ltor then --sometimes we might as for an rvalue and then convert to an lvalue (e.g. on casts), we just undo that here
                return ee.expression
            else
                return terra.newtree(ee,{ kind = terra.kinds.rtol, type = ee.type, expression = ee })
            end
        else
            return ee
        end
    end
    
    local function insertaddressof(ee)
        local e = aslvalue(ee)
        local ret = terra.newtree(e,{ kind = terra.kinds.operator, type = terra.types.pointer(ee.type), operator = terra.kinds["&"], operands = terra.newlist{e} })
        return ret
    end
    local function insertdereference(ee)
        local e = asrvalue(ee)
        local ret = terra.newtree(e,{ kind = terra.kinds.operator, operator = terra.kinds["@"], operands = terra.newlist{e}, lvalue = true })
        if not e.type:ispointer() then
            terra.reporterror(ctx,e,"argument of dereference is not a pointer type but ",e.type)
            ret.type = terra.types.error 
        elseif e.type.type:isfunction() then
            --function pointer dereference does nothing, return the input
            return e
        else
            ret.type = e.type.type
        end
        return ret
    end
    
    local function insertvar(anchor, typ, name, definition)
        return terra.newtree(anchor, { kind = terra.kinds["var"], type = typ, name = name, definition = definition, lvalue = true }) 
    end

    local function insertselect(v, field)
        local tree = terra.newtree(v, { type = terra.types.error, kind = terra.kinds.select, field = field, value = v, lvalue = v.lvalue })
        assert(v.type:isstruct())
        local index = v.type.keytoindex[field]
        
        if index == nil then
            return nil,false
        end
        tree.index = index
        tree.type = v.type.entries[index+1].type
        return tree,true
    end

    --wrappers for l/rvalue version of checking functions
    local function checkrvalue(e)
        local ee = checkexp(e)
        return asrvalue(ee)
    end

    local function checklvalue(ee)
        local e = checkexp(ee)
        if not e.lvalue then
            terra.reporterror(ctx,e,"argument to operator must be an lvalue")
            e.type = terra.types.error
        end
        return e
    end

    --functions handling casting between types
    
    local insertcast --handles implicitly allowed casts (e.g. var a : int = 3.5)
    local insertexplicitcast --handles casts performed explicitly (e.g. var a = int(3.5))
    local structcast -- handles casting from an anonymous structure type to another struct type (e.g. StructFoo { 3, 5 })
    local insertrecievercast -- handles casting for method recievers, which allows for an implicit addressof operator to be inserted

    -- all implicit casts (struct,reciever,generic) take a speculative argument
    --if speculative is true, then errors will not be reported (caller must check)
    --this is used to see if an overloaded function can apply to the argument list

    function structcast(cast,exp,typ, speculative) 
        local from = exp.type
        local to = typ
        
    
        local valid = true
        local function err(...)
            valid = false
            if not speculative then
                terra.reporterror(ctx,exp,...)
            end
        end
        
        cast.structvariable = terra.newtree(exp, { kind = terra.kinds.entry, name = "<structcast>", type = from })
        local var_ref = insertvar(exp,from,cast.structvariable.name,cast.structvariable)
        
        local indextoinit = {}
        for i,entry in ipairs(from.entries) do
            local selected = asrvalue(insertselect(var_ref,entry.key))
            if entry.hasname then
                local offset = to.keytoindex[entry.key]
                if not offset then
                    err("structural cast invalid, result structure has no key ", entry.key)
                else
                    if indextoinit[offset] then
                        err("structural cast invalid, ",entry.key," initialized more than once")
                    end
                    indextoinit[offset] = insertcast(selected,to.entries[offset+1].type)
                end
            else
                local offset = 0
                
                --find the first non initialized entry
                while offset < #to.entries and indextoinit[offset] do
                    offset = offset + 1
                end
                local totyp = to.entries[offset+1] and to.entries[offset+1].type
                local maxsz = #to.entries
                
                if offset == maxsz then
                    err("structural cast invalid, too many unnamed fields")
                else
                    indextoinit[offset] = insertcast(selected,totyp)
                end
            end
        end
        
        cast.entries = terra.newlist()
        for i,v in pairs(indextoinit) do
            cast.entries:insert( { index = i, value = v } )
        end
        
        return cast, valid
    end

    function insertcast(exp,typ,speculative) --if speculative is true, then an error will not be reported and the caller should check the second return value to see if the cast was valid
        if typ == nil then
            print(debug.traceback())
        end
        if typ == exp.type or typ == terra.types.error or exp.type == terra.types.error then
            return exp, true
        else
            local cast_exp = createcast(exp,typ)
            if ((typ:isprimitive() and exp.type:isprimitive()) or
                (typ:isvector() and exp.type:isvector() and typ.N == exp.type.N)) and 
               not typ:islogicalorvector() and not exp.type:islogicalorvector() then
                return cast_exp, true
            elseif typ:ispointer() and exp.type:ispointer() and typ.type == uint8 then --implicit cast from any pointer to &uint8
                return cast_exp, true
            elseif typ:ispointer() and exp.type == terra.types.niltype then --niltype can be any pointer
                return cast_exp, true
            elseif typ:isstruct() and exp.type:isstruct() and exp.type.isconvertible then 
                return structcast(cast_exp,exp,typ,speculative)
            elseif typ:ispointer() and exp.type:isarray() and typ.type == exp.type.type then
                --if we have an rvalue array, it must be converted to lvalue (i.e. placed on the stack) before the cast is valid
                cast_exp.expression = aslvalue(cast_exp.expression)
                return cast_exp, true
            elseif typ:isvector() and exp.type:isprimitive() then
                local primitivecast, valid = insertcast(exp,typ.type,speculative)
                local broadcast = createcast(primitivecast,typ)
                return broadcast, valid
            end

            --no builtin casts worked... now try user-defined casts
            local cast_fns = terra.newlist()
            local function addcasts(typ)
                if typ:isstruct() and typ.methods.__cast then
                    cast_fns:insert(typ.methods.__cast)
                elseif typ:ispointertostruct() then
                    addcasts(typ.type)
                end
            end
            addcasts(exp.type)
            addcasts(typ)

            for i,__cast in ipairs(cast_fns) do
                local tel = createtypedexpressionlist(exp,terra.newlist{exp},nil)
                local quotedexp = terra.newquote(tel)
                local success,valid,result = invokeuserfunction(exp, true,__cast,diag,exp,exp.type,typ,quotedexp)
                if success and valid then
                    return checkrvalue(terra.createterraexpression(diag,exp,result))
                end
            end

            if not speculative then
                terra.reporterror(ctx,exp,"invalid conversion from ",exp.type," to ",typ)
            end
            return cast_exp, false
        end
    end
    function insertexplicitcast(exp,typ) --all implicit casts are allowed plus some additional casts like from int to pointer, pointer to int, and int to int
        if typ == exp.type then
            return exp
        elseif typ:ispointer() and exp.type:ispointer() then
            return createcast(exp,typ)
        elseif typ:ispointer() and exp.type:isintegral() then --int to pointer
            return createcast(exp,typ)
        elseif typ:isintegral() and exp.type:ispointer() then
            if typ.bytes < intptr.bytes then
                terra.reporterror(ctx,exp,"pointer to ",typ," conversion loses precision")
            end
            return createcast(exp,typ)
        elseif typ:isprimitive() and exp.type:isprimitive() then --explicit conversions from logicals to other primitives are allowed
            return createcast(exp,typ)
        else
            return insertcast(exp,typ) --otherwise, allow any implicit casts
        end
    end
    function insertrecievercast(exp,typ,speculative) --casts allow for method recievers a:b(c,d) ==> b(a,c,d), but 'a' has additional allowed implicit casting rules
                                                      --type can also be == "vararg" if the expected type of the reciever was an argument to the varargs of a function (this often happens when it is a lua function)
         if typ == "vararg" then
             return insertaddressof(exp), true
         elseif typ:ispointer() and not exp.type:ispointer() then
             --implicit address of allowed for recievers
             return insertcast(insertaddressof(exp),typ,speculative)
         else
            return insertcast(exp,typ,speculative)
        end
        --notes:
        --we force vararg recievers to be a pointer
        --an alternative would be to return reciever.type in this case, but when invoking a lua function as a method
        --this would case the lua function to get a pointer if called on a pointer, and a value otherwise
        --in other cases, you would consistently get a value or a pointer regardless of receiver type
        --for consistency, we all lua methods take pointers
        --TODO: should we also consider implicit conversions after the implicit address/dereference? or does it have to match exactly to work?
    end


    --functions to typecheck operator expressions
    
    local function typemeet(op,a,b)
        local function err()
            terra.reporterror(ctx,op,"incompatible types: ",a," and ",b)
        end
        if a == terra.types.error or b == terra.types.error then
            return terra.types.error
        elseif a == b then
            return a
        elseif a.kind == terra.kinds.primitive and b.kind == terra.kinds.primitive then
            if a:isintegral() and b:isintegral() then
                if a.bytes < b.bytes then
                    return b
                elseif b.bytes > a.bytes then
                    return a
                elseif a.signed then
                    return b
                else --a is unsigned but b is signed
                    return a
                end
            elseif a:isintegral() and b:isfloat() then
                return b
            elseif a:isfloat() and b:isintegral() then
                return a
            elseif a:isfloat() and b:isfloat() then
                return double
            else
                err()
                return terra.types.error
            end
        elseif a:ispointer() and b == terra.types.niltype then
            return a
        elseif a == terra.types.niltype and b:ispointer() then
            return b
        elseif a:isvector() and b:isvector() and a.N == b.N then
            local rt, valid = typemeet(op,a.type,b.type)
            return (rt == terra.types.error and rt) or terra.types.vector(rt,a.N)
        elseif (a:isvector() and b:isprimitive()) or (b:isvector() and a:isprimitive()) then
            if a:isprimitive() then
                a,b = b,a --ensure a is vector and b is primitive
            end
            local rt = typemeet(op,a.type,b)
            return (rt == terra.types.error and rt) or terra.types.vector(rt,a.N)
        else    
            err()
            return terra.types.error
        end
    end

    local function typematch(op,lstmt,rstmt)
        local inputtype = typemeet(op,lstmt.type,rstmt.type)
        return inputtype, insertcast(lstmt,inputtype), insertcast(rstmt,inputtype)
    end

    local function checkunary(ee,operands,property)
        local e = operands[1]
        if e.type ~= terra.types.error and not e.type[property](e.type) then
            terra.reporterror(ctx,e,"argument of unary operator is not valid type but ",e.type)
            return e:copy { type = terra.types.error }
        end
        return ee:copy { type = e.type, operands = terra.newlist{e} }
    end 
    
    
    local function meetbinary(e,property,lhs,rhs)
        local t,l,r = typematch(e,lhs,rhs)
        if t ~= terra.types.error and not t[property](t) then
            terra.reporterror(ctx,e,"arguments of binary operator are not valid type but ",t)
            return e:copy { type = terra.types.error }
        end
        return e:copy { type = t, operands = terra.newlist {l,r} }
    end
    
    local function checkbinaryorunary(e,operands,property)
        if #operands == 1 then
            return checkunary(e,operands,property)
        end
        return meetbinary(e,property,operands[1],operands[2])
    end
    
    local function checkarith(e,operands)
        return checkbinaryorunary(e,operands,"isarithmeticorvector")
    end

    local function checkarithpointer(e,operands)
        if #operands == 1 then
            return checkunary(e,operands,"isarithmeticorvector")
        end
        
        local l,r = unpack(operands)
        
        local function pointerlike(t)
            return t:ispointer() or t:isarray()
        end
        local function aspointer(exp) --convert pointer like things into pointers
            return (insertcast(exp,terra.types.pointer(exp.type.type)))
        end
        -- subtracting 2 pointers
        if  pointerlike(l.type) and pointerlike(r.type) and l.type.type == r.type.type and e.operator == terra.kinds["-"] then
            return e:copy { type = ptrdiff, operands = terra.newlist {aspointer(l),aspointer(r)} }
        elseif pointerlike(l.type) and r.type:isintegral() then -- adding or subtracting a int to a pointer 
            return e:copy { type = terra.types.pointer(l.type.type), operands = terra.newlist {aspointer(l),r} }
        elseif l.type:isintegral() and pointerlike(r.type) then
            return e:copy { type = terra.types.pointer(r.type.type), operands = terra.newlist {aspointer(r),l} }
        else
            return meetbinary(e,"isarithmeticorvector",l,r)
        end
    end

    local function checkintegralarith(e,operands)
        return checkbinaryorunary(e,operands,"isintegralorvector")
    end
    
    local function checkcomparision(e,operands)
        local t,l,r = typematch(e,operands[1],operands[2])
        local rt = bool
        if t:isvector() then
            rt = terra.types.vector(bool,t.N)
        end
        return e:copy { type = rt, operands = terra.newlist {l,r} }
    end
    
    local function checklogicalorintegral(e,operands)
        return checkbinaryorunary(e,operands,"canbeordorvector")
    end
    
    local function checkshift(ee,operands)
        local a,b = unpack(operands)
        local typ = terra.types.error
        if a.type ~= terra.types.error and b.type ~= terra.types.error then
            if a.type:isintegralorvector() and b.type:isintegralorvector() then
                if a.type:isvector() then
                    typ = a.type
                elseif b.type:isvector() then
                    typ = terra.types.vector(a.type,b.type.N)
                else
                    typ = a.type
                end
                
                a = insertcast(a,typ)
                b = insertcast(b,typ)
            
            else
                terra.reporterror(ctx,ee,"arguments to shift must be integers but found ",a.type," and ", b.type)
            end
        end
        
        return ee:copy { type = typ, operands = terra.newlist{a,b} }
    end
    
    
    local function checkifelse(ee,operands)
        local cond = operands[1]
        local t,l,r = typematch(ee,operands[2],operands[3])
        if cond.type ~= terra.types.error and t ~= terra.types.error then
            if cond.type:isvector() and cond.type.type == bool then
                if not t:isvector() or t.N ~= cond.type.N then
                    print(ee)
                    terra.reporterror(ctx,ee,"conditional in select is not the same shape as ",cond.type)
                end
            elseif cond.type ~= bool then
                print(ee)
                terra.reporterror(ctx,ee,"expected a boolean or vector of booleans but found ",cond.type)   
            end
        end
        return ee:copy { type = t, operands = terra.newlist{cond,l,r}}
    end

    local function gettreeattribute(tree,attrname,typ)
        local attr = tree.attributes and tree.attributes[attrname]
        if attr and typ ~= type(attr) then
            terra.reporterror(ctx,tree,attrname," requires type ", typ, " but found ", type(attr))
            return nil
        end
        return attr
    end

    local operator_table = {
        ["-"] = { checkarithpointer, "__sub" };
        ["+"] = { checkarithpointer, "__add" };
        ["*"] = { checkarith, "__mul" };
        ["/"] = { checkarith, "__div" };
        ["%"] = { checkarith, "__mod" };
        ["<"] = { checkcomparision, "__lt" };
        ["<="] = { checkcomparision, "__le" };
        [">"] = { checkcomparision, "__gt" };
        [">="] =  { checkcomparision, "__ge" };
        ["=="] = { checkcomparision, "__eq" };
        ["~="] = { checkcomparision, "__ne" };
        ["and"] = { checklogicalorintegral, "__and" };
        ["or"] = { checklogicalorintegral, "__or" };
        ["not"] = { checklogicalorintegral, "__not" };
        ["^"] =  { checkintegralarith, "__xor" };
        ["<<"] = { checkshift, "__lshift" };
        [">>"] = { checkshift, "__rshift" };
        ["select"] = { checkifelse, "__select"}
    }
    
    local function checkoperator(ee)
        local op_string = terra.kinds[ee.operator]
        
        --check non-overloadable operators first
        if op_string == "@" then
            local e = checkrvalue(ee.operands[1])
            return insertdereference(e)
        elseif op_string == "&" then
            local e = checklvalue(ee.operands[1])
            local ty = terra.types.pointer(e.type)
            return ee:copy { type = ty, operands = terra.newlist{e} }
        end
        
        local op, overloadmethod = unpack(operator_table[op_string] or {})
        if op == nil then
            diag:reporterror(ee,"operator ",op_string," not defined in terra code.")
            return ee:copy { type = terra.types.error }
        end
        local operands = ee.operands:map(checkrvalue)
        
        local overloads = terra.newlist()
        for i,e in ipairs(operands) do
            if e.type:isstruct() then
                local overload = e.type.methods[overloadmethod] --TODO: be more intelligent here about merging overloaded functions so that all possibilities are considered
                if overload then
                    overloads:insert(terra.createterraexpression(diag, ee, overload))
                end
            end
        end
        
        if #overloads > 0 then
            local function wrapexp(exp)
                return createtypedexpressionlist(exp,terra.newlist{exp},nil)
            end
            return checkcall(ee, overloads, operands:map(wrapexp), "all", true, false)
        else
            return op(ee,operands)
        end

    end

    --functions to handle typecheck invocations (functions,methods,macros,operator overloads)

    function checkparameterlist(anchor,params) --individual params may be already typechecked (e.g. if they were a method call receiver) 
                                                                --in this case they are treated as single expressions
        local exps = terra.newlist()
        local fncall = nil
        
        local minsize = #params --minsize is either the number of explicitly listed parameters (a,b,c) minsize == 3
                                --or 1 less than this number if 'c' is a macro/quotelist that has 0 elements
        for i,p in ipairs(params) do
            if i ~= #params then
                exps:insert(checkrvalue(p))
            else
                local explist = checkexp(p,true,false)
                fncall = explist.fncall
                if #explist.expressions == 0 then
                    minsize = minsize - 1
                end
                for i,a in ipairs(explist.expressions) do
                    exps:insert(asrvalue(a))
                end
            end
        end
        return createtypedexpressionlist(anchor, exps, fncall, minsize)
    end

    local function insertvarargpromotions(param)
        if param.type == float then
            return insertcast(param,double)
        end
        --TODO: do we need promotions for integral data types or does llvm already do that?
        return param
    end

    local function tryinsertcasts(typelists,castbehavior, speculate, allowambiguous, paramlist)
        local minsize, maxsize = paramlist.minsize, #paramlist.expressions
        local function trylist(typelist, speculate)
            local allvalid = true
            if #typelist > maxsize then
                allvalid = false
                if not speculate then
                    terra.reporterror(ctx,paramlist,"expected at least "..#typelist.." parameters, but found "..maxsize)
                end
            elseif #typelist < minsize then
                allvalid = false
                if not speculate then
                    terra.reporterror(ctx,paramlist,"expected no more than "..#typelist.." parameters, but found at least "..minsize)
                end
            end
            
            local results = terra.newlist{}
            
            for i,param in ipairs(paramlist.expressions) do
                local typ = typelist[i]
                
                local result,valid
                if typ == nil or typ == "passthrough" then
                    result,valid = param,true 
                elseif castbehavior == "all" or (i == 1 and castbehavior == "first") then
                    result,valid = insertrecievercast(param,typ,speculate)
                elseif typ == "vararg" then
                    result,valid = insertvarargpromotions(param),true
                else
                    result,valid = insertcast(param,typ,speculate)
                end
                results[i] = result
                allvalid = allvalid and valid
            end
            
            return results,allvalid
        end
        
        local function shortenparamlist(size)
            if #paramlist.expressions > size then --could already be shorter on error
                for i = size+1,maxsize do
                    paramlist.expressions[i] = nil
                end
                assert(#paramlist.expressions == size) 
            end
        end

        if #typelists == 1 then
            local typelist = typelists[1]    
            local results,allvalid = trylist(typelist,false)
            assert(#results == maxsize)
            paramlist.expressions = results
            shortenparamlist(#typelist)
            return 1
        else
            --evaluate each potential list
            local valididx,validcasts
            for i,typelist in ipairs(typelists) do
                local results,allvalid = trylist(typelist,true)
                if allvalid then
                    if valididx == nil then
                        valididx = i
                        validcasts = results
                        if allowambiguous then
                            break
                        end
                    else
                        local optiona = typelists[valididx]:mkstring("(",",",")")
                        local optionb = typelist:mkstring("(",",",")")
                        terra.reporterror(ctx,paramlist,"call to overloaded function is ambiguous. can apply to both ", optiona, " and ", optionb)
                        break
                    end
                end
            end
            
            if valididx then
               paramlist.expressions = validcasts
               shortenparamlist(#typelists[valididx])
            else
                --no options were valid and our caller wants us to, lets emit some errors
                if not speculate then
                    diag:reporterror(paramlist,"call to overloaded function does not apply to any arguments")
                    for i,typelist in ipairs(typelists) do
                        terra.reporterror(ctx,paramlist,"option ",i," with type ",typelist:mkstring("(",",",")"))
                        trylist(typelist,false)
                    end
                end
            end
            return valididx
        end
    end
    
    local function insertcasts(typelist,paramlist) --typelist is a list of target types (or the value "passthrough"), paramlist is a parameter list that might have a multiple return value at the end
        return tryinsertcasts(terra.newlist { typelist }, "none", false, false, paramlist)
    end

    local function checkmethodwithreciever(anchor, methodtablename, methodname, reciever, arguments, isstatement)
        local fnlike
        if reciever.type:isstruct() then
            fnlike = reciever.type[methodtablename][methodname]
        elseif reciever.type:ispointertostruct() then
            fnlike = reciever.type.type[methodtablename][methodname]
            reciever = insertdereference(reciever)
        end

        if not fnlike then
            diag:reporterror(anchor,"no such method ",methodname," defined for type ",reciever.type)
            return anchor:copy { type = terra.types.error }
        end

        fnlike = terra.createterraexpression(diag, anchor, fnlike) 
        local wrappedrecv = createtypedexpressionlist(anchor,terra.newlist {reciever},nil)
        local fnargs = terra.newlist { wrappedrecv }
        for i,a in ipairs(arguments) do
            fnargs:insert(a)
        end
        
        return checkcall(anchor, terra.newlist { fnlike }, fnargs, "first", false, isstatement)
    end

    local function checkmethod(exp, isstatement)
        local methodname = exp.name
        assert(type(methodname) == "string" or terra.issymbol(methodname))
        local reciever = checkexp(exp.value)
        local arguments = exp.arguments:map( function(a) return checkexp(a,true,true) end )
        return checkmethodwithreciever(exp, "methods", methodname, reciever, arguments, isstatement)
    end

    local function checkapply(exp, isstatement)
        local fnlike = checkexp(exp.value,false,true)
        local arguments = exp.arguments:map( function(a) return checkexp(a,true,true) end )
    
        if not fnlike:is "luaobject" then
            if fnlike.type:isstruct() or fnlike.type:ispointertostruct() then
                return checkmethodwithreciever(exp, "methods", "__apply", fnlike, arguments, isstatement) 
            end
            fnlike = asrvalue(fnlike)
        end
        return checkcall(exp, terra.newlist { fnlike } , arguments, "none", false, isstatement)
    end
    
    function checkcall(anchor, fnlikelist, arguments, castbehavior, allowambiguous, isstatement)
        --arguments are always typedexpressions or luaobjects
        for i,a in ipairs(arguments) do
            assert(a:is "typedexpressionlist")
        end
        assert(#fnlikelist > 0)
        
        --collect all the terra functions, stop collecting when we reach the first 
        --alternative that is not a terra function and record it as fnlike
        --we will first attempt to typecheck the terra functions, and if they fail,
        --we will call the macro/luafunction (these can take any argument types so they will always work)
        local terrafunctions = terra.newlist()
        local fnlike = nil
        for i,fn in ipairs(fnlikelist) do
            if fn:is "luaobject" then
                if terra.ismacro(fn.value) or type(fn.value) == "function" then
                    fnlike = fn.value
                    break
                elseif terra.types.istype(fn.value) then
                    local castmacro = macro(function(ctx,tree,arg)
                        return terra.newtree(tree, { kind = terra.kinds.explicitcast, value = arg.tree, totype = fn.value })
                    end)
                    fnlike = castmacro
                    break
                elseif terra.isfunction(fn.value) then
                    if #fn.value:getvariants() == 0 then
                        diag:reporterror(anchor,"attempting to call undefined function")
                    end
                    for i,v in ipairs(fn.value:getvariants()) do
                        local fnlit = createfunctionliteral(anchor,v)
                        if fnlit.type ~= terra.types.error then
                            terrafunctions:insert( fnlit )
                        end
                    end
                else
                    terra.reporterror(ctx,anchor,"expected a function or macro but found lua value of type ",type(fn.value))
                end
            elseif fn.type:ispointer() and fn.type.type:isfunction() then
                terrafunctions:insert(fn)
            else
                if fn.type ~= terra.types.error then
                    terra.reporterror(ctx,anchor,"expected a function but found ",fn.type)
                end
            end 
        end

        local function createcall(callee, paramlist)
            local returntypes = callee.type.type.returns
            local paramtypes = paramlist.expressions:map(function(x) return x.type end)
            local fncall = terra.newtree(anchor, { kind = terra.kinds.apply, arguments = paramlist, value = callee, returntypes = returntypes, paramtypes = paramtypes })
            local expressions = terra.newlist()
            for i,rt in ipairs(returntypes) do
                expressions[i] = createextractreturn(anchor,i-1, rt)
            end 
            return createtypedexpressionlist(anchor,expressions,fncall)
        end
        local function generatenativewrapper(fn,paramlist)
            local varargslist = paramlist.expressions:map(function(p) return "vararg" end)
            tryinsertcasts(terra.newlist{varargslist},castbehavior, false, false, paramlist)
            local paramtypes = paramlist.expressions:map(function(p) return p.type end)
            local castedtype = terra.types.funcpointer(paramtypes,{})
            local cb = terra.cast(castedtype,fn)
            local fptr = terra.pointertolightuserdata(cb)
            return terra.newtree(anchor, { kind = terra.kinds.luafunction, callback = cb, fptr = fptr, type = castedtype })
        end

        local paramlist
        if #terrafunctions > 0 then
            paramlist = checkparameterlist(anchor,arguments)
            local function getparametertypes(fn) --get the expected types for parameters to the call (this extends the function type to the length of the parameters if the function is vararg)
                local fntyp = fn.type.type
                if not fntyp.isvararg then
                    return fntyp.parameters
                end
                
                local vatypes = terra.newlist()
                for i,v in ipairs(paramlist.expressions) do
                    if i <= #fntyp.parameters then
                        vatypes[i] = fntyp.parameters[i]
                    else
                        vatypes[i] = "vararg"
                    end
                end
                return vatypes
            end
            local typelists = terrafunctions:map(getparametertypes)
            local valididx = tryinsertcasts(typelists,castbehavior, fnlike ~= nil, allowambiguous, paramlist)
            if valididx then
                return createcall(terrafunctions[valididx],paramlist)
            end
        end

        if fnlike then
            if terra.ismacro(fnlike) then
                local quotes = arguments:map(terra.newquote)
                local success, result = invokeuserfunction(anchor, false, fnlike, ctx, anchor, unpack(quotes))
                
                if success then
                    local newexp = terra.createterraexpression(diag,anchor,result)
                    if isstatement then
                        return checkstmt(newexp)
                    else
                        return checkexp(newexp,true,true) --TODO: is true,true right? we will need tests
                    end
                else
                    return anchor:copy { type = terra.types.error }
                end
            elseif type(fnlike) == "function" then
                paramlist = paramlist or checkparameterlist(anchor,arguments)
                local callee = generatenativewrapper(fnlike,paramlist)
                return createcall(callee,paramlist)
            else 
                error("fnlike is not a function/macro?")
            end
        end
        assert(diag:haserrors())
        return anchor:copy { type = terra.types.error }
    end

    --functions that handle the checking of expressions
    
    local function checkintrinsic(e,mustreturnatleast1)
        local params = checkparameterlist(e,e.arguments)
        local paramtypes = terra.newlist()
        for i,p in ipairs(params.expressions) do
            paramtypes:insert(p.type)
        end
        local name,intrinsictype = e.typefn(paramtypes,params.minsize)
        if type(name) ~= "string" then
            terra.reporterror(ctx,e,"expected an intrinsic name but found ",tostring(name))
            return e:copy { type = terra.types.error }
        elseif intrinsictype == terra.types.error then
            terra.reporterror(ctx,e,"instrinsic ",name," does not support arguments: ",unpack(paramtypes))
            return e:copy { type = terra.types.error }
        elseif not terra.types.istype(intrinsictype) or not intrinsictype:ispointertofunction() then
            terra.reporterror(ctx,e,"expected intrinsic to resolve to a function type but found ",tostring(intrinsictype))
            return e:copy { type = terra.types.error }
        elseif (#intrinsictype.type.returns == 0 and mustreturnatleast1) or (#intrinsictype.type.returns > 1) then
            terra.reporterror(ctx,e,"instrinsic used in an expression must return 1 argument")
            return e:copy { type = terra.types.error }
        end
        
        insertcasts(intrinsictype.type.parameters,params)
        
        return e:copy { type = intrinsictype.type.returns[1], name = name, arguments = params, intrinsictype = intrinsictype }
    end

    local function truncateexpressionlist(tel)
        assert(tel:is "typedexpressionlist")
        if #tel.expressions == 0 then
            diag:reporterror(tel, "expression resulting in no values used where at least one value is required")
            return tel:copy { type = terra.types.error }
        else
            local r = tel.expressions[1]
            if r:is "extractreturn" then --this is a function call so we need to return a typedexpression list to retain the function call  
                assert(tel.fncall ~= nil)
                assert(terra.types.istype(r.type))
                local result = createtypedexpressionlist(tel,terra.newlist { r }, tel.fncall)
                result.type = r.type
                return result
            else -- it is not a function call node, so we can truncate by just returnting the first element
                return r
            end
        end
    end

    local function checksymbol(sym)
        assert(terra.issymbol(sym) or type(sym) == "string")
        return sym
    end

    function checkexp(e_,notruncate, allowluaobjects) -- if notruncate == true, then checkexp will _always_ return a typedexpressionlist tree node, these nodes may contain "luaobject" values
                
        --this function will return either 1 tree, or a list of trees and a function call
        --checkexp then makes the return value consistent with the notruncate argument
        local function docheck(e)
            if e:is "luaobject" then
                return e
            elseif e:is "literal" then
                return e
            elseif e:is "constant"  then
                return e
            elseif e:is "var" then
                assert(e.value) --value should be added during specialization. it is a symbol in the currently symbol environment if this is a local variable
                                --otherwise it a reference to the global variable object to which it refers
                local definition = (terra.isglobalvar(e.value) and e.value) or symbolenv:localenv()[e.value]

                if not definition then
                    diag:reporterror(e, "definition of this variable is not in scope")
                    return e:copy { type = terra.types.error }
                end

                assert(terra.istree(definition) or terra.isglobalvar(definition))
                assert(terra.types.istype(definition.type))

                return e:copy { type = definition.type, definition = definition }
            elseif e:is "select" then
                local v = checkexp(e.value)
                local field = checksymbol(e.field)
                if v.type:ispointertostruct() then --allow 1 implicit dereference
                    v = insertdereference(v)
                end

                if v.type:isstruct() then
                    local ret, success = insertselect(v,field)
                    if not success then
                        --struct has no member field, look for a getter __get<field>
                        local getter = type(field) == "string" and v.type.methods["__get"..field]
                        if getter then
                            getter = terra.createterraexpression(diag, e, getter) 
                            local til = createtypedexpressionlist(v, terra.newlist { v } ) 
                            return checkcall(v, terra.newlist{ getter }, terra.newlist { til }, "first", false, false)
                        else
                            diag:reporterror(v,"no field ",field," in terra object of type ",v.type)
                            return e:copy { type = terra.types.error }
                        end
                    else
                        return ret
                    end
                else
                    diag:reporterror(v,"expected a structural type")
                    return e:copy { type = terra.types.error }
                end
            elseif e:is "typedexpressionlist" then --expressionlist that has been previously typechecked and re-injected into the compiler
                if e.key ~= typedexpressionkey then --if it went through a macro, it could have been retained by lua code and returned to a different function
                                                    --we check that this didn't happen by checking that it has an expression key unique to this function
                    diag:reporterror(e,"cannot use a typed expression from one function in another")
                end
                return e
            elseif e:is "operator" then
                return checkoperator(e)
            elseif e:is "index" then
                local v = checkexp(e.value)
                local idx = checkrvalue(e.index)
                local typ,lvalue
                if v.type:ispointer() or v.type:isarray() or v.type:isvector() then
                    typ = v.type.type
                    if not idx.type:isintegral() and idx.type ~= terra.types.error then
                        terra.reporterror(ctx,e,"expected integral index but found ",idx.type)
                    end
                    if v.type:ispointer() then
                        v = asrvalue(v)
                        lvalue = true
                    elseif v.type:isarray() then
                        lvalue = v.lvalue
                    elseif v.type:isvector() then
                        v = asrvalue(v)
                        lvalue = nil
                    end
                else
                    typ = terra.types.error
                    if v.type ~= terra.types.error then
                        terra.reporterror(ctx,e,"expected an array or pointer but found ",v.type)
                    end
                end
                return e:copy { type = typ, lvalue = lvalue, value = v, index = idx }
            elseif e:is "explicitcast" then
                return insertexplicitcast(checkrvalue(e.value),e.totype)
            elseif e:is "sizeof" then
                return e:copy { type = uint64 }
            elseif e:is "vectorconstructor" or e:is "arrayconstructor" then
                local entries = checkparameterlist(e,e.expressions)
                local N = #entries.expressions
                         
                local typ
                if e.oftype ~= nil then
                    typ = e.oftype
                else
                    if N == 0 then
                        terra.reporterror(ctx,e,"cannot determine type of empty aggregate")
                        return e:copy { type = terra.types.error }
                    end
                    
                    --figure out what type this vector has
                    typ = entries.expressions[1].type
                    for i,p in ipairs(entries.expressions) do
                        typ = typemeet(e,typ,p.type)
                    end
                end
                
                local aggtype
                if e:is "vectorconstructor" then
                    if not typ:isprimitive() and typ ~= terra.types.error then
                        terra.reporterror(ctx,e,"vectors must be composed of primitive types (for now...) but found type ",type(typ))
                        return e:copy { type = terra.types.error }
                    end
                    aggtype = terra.types.vector(typ,N)
                else
                    aggtype = terra.types.array(typ,N)
                end
                
                --insert the casts to the right type in the parameter list
                local typs = entries.expressions:map(function(x) return typ end)
                
                insertcasts(typs,entries)
                
                return e:copy { type = aggtype, expressions = entries }
                
            elseif e:is "apply" then
                return checkapply(e,false)
            elseif e:is "method" then
                return checkmethod(e,false)
            elseif e:is "truncate" then
                return checkexp(e.value, false, allowluaobjects)
            elseif e:is "treelist" then
                local results = terra.newlist()
                local fncall = nil
                for i,v in ipairs(e.values) do
                    if v:is "luaobject" then
                        results:insert(v)
                    elseif i == #e.values then
                        local tel = checkexp(v,true)
                        for i,e in ipairs(tel.expressions) do
                            results:insert(e)
                        end
                        fncall = tel.fncall
                    else
                        results:insert(checkexp(v))
                    end
                end
                return createtypedexpressionlist(e,results,fncall)
           elseif e:is "constructor" then
                local typ = terra.types.newstruct("anon")
                typ:setconvertible(true)
                
                local paramlist = terra.newlist{}
                
                for i,f in ipairs(e.records) do
                    local value = f.value
                    if i == #e.records and f.key then
                        value = terra.newtree(value, { kind = terra.kinds.truncate, value = value })
                    end
                    paramlist:insert(value)
                end

                local entries = checkparameterlist(e,paramlist)
                
                for i,v in ipairs(entries.expressions) do
                    local k = e.records[i] and e.records[i].key
                    k = k and checksymbol(k)
                    if not typ:addentry(k,v.type) then
                        terra.reporterror(ctx,v,"duplicate definition of field ",k)
                    end
                end
                return e:copy { expressions = entries, type = typ:freeze(diag) }
            elseif e:is "intrinsic" then
                return checkintrinsic(e,true)
            else
                diag:reporterror(e,"statement found where an expression is expected ", terra.kinds[e.kind])
                return e:copy { type = terra.types.error }
            end
        end
        
        --check the expression, may return 1 value or multiple
        local result = docheck(e_)
        --freeze all types returned by the expression (or list of expressions)
        local isexpressionlist = result:is "typedexpressionlist"
        if isexpressionlist then
            for i,e in ipairs(result.expressions) do
                if not e:is "luaobject" then
                    assert(terra.types.istype(e.type))
                    e.type:freeze(diag)
                end
            end
        elseif not result:is "luaobject" then
            assert(terra.types.istype(result.type))
            result.type:freeze(diag)
        end

        --remove any lua objects if they are not allowed in this context
        
        if not allowluaobjects then
            local function removeluaobject(e)
                if e.type == terra.types.error then return e end --don't repeat error messages
                if terra.isfunction(e.value) then
                    local variants = e.value:getvariants()
                    if #variants ~= 1 then
                        diag:reporterror(e,(#variants == 0 and "undefined") or "overloaded", " functions cannot be used as values")
                        return e:copy { type = terra.types.error }
                    end
                    return createfunctionliteral(e,variants[1])
                else
                    diag:reporterror(e, "expected a terra expression but found ",type(result.value))
                    return e:copy { type = terra.types.error }
                end
            end
            if isexpressionlist then
                local exps = result.expressions:map( function(e) 
                    return (e:is "luaobject" and removeluaobject(e)) or e
                end)
                result = result:copy { expressions = exps }
            elseif result:is "luaobject" then
                result = removeluaobject(result)
            end
        end

        --normalize the return type to the requested type
        if isexpressionlist then
            return (notruncate and result) or truncateexpressionlist(result)
        else
            return (notruncate and createtypedexpressionlist(e_,terra.newlist {result},nil)) or result
        end
    end

    --helper functions used in checking statements:
    
    local function checkexptyp(re,target)
        local e = checkrvalue(re)
        if e.type ~= target then
            terra.reporterror(ctx,e,"expected a ",target," expression but found ",e.type)
            e.type = terra.types.error
        end
        return e
    end
    local function checkcondbranch(s)
        local e = checkexptyp(s.condition,bool)
        local b = checkstmt(s.body)
        return s:copy {condition = e, body = b}
    end

    local function checkformalparameterlist(params)
        for i, p in ipairs(params) do
            assert(type(p.name) == "string")
            assert(terra.issymbol(p.symbol))
            if p.type then
                assert(terra.types.istype(p.type))
                p.type:freeze(diag)
            end
        end
        --copy the entries since we mutate them and this list could appear multiple times in the tree
        return params:map(function(x) return x:copy{}  end) 
    end


    --state that is modified by checkstmt:
    
    local return_stmts = terra.newlist() --keep track of return stms, these will be merged at the end, possibly inserting casts
    
    local labels = {} --map from label name to definition (or, if undefined to the list of already seen gotos that target that label)
    local loopstmts = terra.newlist() -- stack of loopstatements (for resolving where a break goes)
    
    local function enterloop()
        local bt = {}
        loopstmts:insert(bt)
        return bt
    end
    local function leaveloop()
        loopstmts:remove()
    end
    
    -- checking of statements

    function checkstmt(s)
        if s:is "block" then
            symbolenv:enterblock()
            local r = s.statements:flatmap(checkstmt)
            symbolenv:leaveblock()
            return s:copy {statements = r}
        elseif s:is "return" then
            local rstmt = s:copy { expressions = checkparameterlist(s,s.expressions) }
            return_stmts:insert( rstmt )
            return rstmt
        elseif s:is "label" then
            local ss = s:copy {}
            local label = checksymbol(ss.value)
            ss.labelname = tostring(label)
            local lbls = labels[label] or terra.newlist()
            if terra.istree(lbls) then
                terra.reporterror(ctx,s,"label defined twice")
                terra.reporterror(ctx,lbls,"previous definition here")
            else
                for _,v in ipairs(lbls) do
                    v.definition = ss
                end
            end
            labels[label] = ss
            return ss
        elseif s:is "goto" then
            local ss = s:copy{}
            local label = checksymbol(ss.label)
            local lbls = labels[label] or terra.newlist()
            if terra.istree(lbls) then
                ss.definition = lbls
            else
                lbls:insert(ss)
            end
            labels[label] = lbls
            return ss
        elseif s:is "break" then
            local ss = s:copy({})
            if #loopstmts == 0 then
                terra.reporterror(ctx,s,"break found outside a loop")
            else
                ss.breaktable = loopstmts[#loopstmts]
            end
            return ss
        elseif s:is "while" then
            local breaktable = enterloop()
            local r = checkcondbranch(s)
            r.breaktable = breaktable
            leaveloop()
            return r
        elseif s:is "if" then
            local br = s.branches:map(checkcondbranch)
            local els = (s.orelse and checkstmt(s.orelse)) or terra.newtree(s, { kind = terra.kinds.block, statements = terra.newlist() })
            return s:copy{ branches = br, orelse = els }
        elseif s:is "repeat" then
            local breaktable = enterloop()
            symbolenv:enterblock() --we don't use block here because, unlike while loops, the condition needs to be checked in the scope of the loop
            local new_blk = s.body:copy { statements = s.body.statements:map(checkstmt) }
            local e = checkexptyp(s.condition,bool)
            symbolenv:leaveblock()
            leaveloop()
            return s:copy { body = new_blk, condition = e, breaktable = breaktable }
        elseif s:is "defvar" then
            local res
            
            local lhs = checkformalparameterlist(s.variables)

            if s.initializers then
                local params = checkparameterlist(s,s.initializers)
                
                local vtypes = terra.newlist()
                for i,v in ipairs(lhs) do
                    vtypes:insert(v.type or "passthrough")
                end
                


                insertcasts(vtypes,params)
                
                for i,v in ipairs(lhs) do
                    v.type = (params.expressions[i] and params.expressions[i].type) or terra.types.error
                end
                
                res = s:copy { variables = lhs, initializers = params }
            else
                res = s:copy { variables = lhs }
            end     
            --add the variables to current environment
            for i,v in ipairs(lhs) do
                assert(terra.issymbol(v.symbol))
                symbolenv:localenv()[v.symbol] = v
            end
            return res
        elseif s:is "assignment" then
            
            local params = checkparameterlist(s,s.rhs)
            
            local lhs = terra.newlist()
            local vtypes = terra.newlist()
            for i,l in ipairs(s.lhs) do
                local ll = checklvalue(l)
                vtypes:insert(ll.type)
                lhs:insert(ll)
            end
            
            insertcasts(vtypes,params)
            
            return s:copy { lhs = lhs, rhs = params }
        elseif s:is "apply" then
            return checkapply(s,true)
        elseif s:is "method" then
            return checkmethod(s,true)
        elseif s:is "treelist" then
            return s.values:flatmap(checkstmt)
        elseif s:is "intrinsic" then
            return checkintrinsic(s,false)
        else
            return checkexp(s,true)
        end
        error("NYI - "..terra.kinds[s.kind],2)
    end
    


    -- actual implementation of typechecking the function begins here

    --  generate types for parameters, if return types exists generate a types for them as well
    local typed_parameters = checkformalparameterlist(ftree.parameters)
    local parameter_types = terra.newlist() --just the types, used to create the function type
    for _,v in ipairs(typed_parameters) do
        assert(terra.types.istype(v.type))
        assert(terra.issymbol(v.symbol))
        parameter_types:insert( v.type )
        symbolenv:localenv()[v.symbol] = v
    end


    local result = checkstmt(ftree.body)

    --check the label table for any labels that have been referenced but not defined
    for _,v in pairs(labels) do
        if not terra.istree(v) then
            terra.reporterror(ctx,v[1],"goto to undefined label")
        end
    end
    
    
    dbprint(2,"Return Stmts:")
    
    --calculate the return type based on either the declared return type, or the return statements

    local return_types
    if ftree.return_types then --take the return types to be as specified
        return_types = ftree.return_types
        for i,r in ipairs(return_types) do
            r:freeze(diag)
        end
    else --calculate the meet of all return type to calculate the actual return type
        if #return_stmts == 0 then
            return_types = terra.newlist()
        else
            local minsize,maxsize
            for _,stmt in ipairs(return_stmts) do
                if return_types == nil then
                    return_types = terra.newlist()
                    for i,exp in ipairs(stmt.expressions.expressions) do
                        return_types[i] = exp.type
                    end
                    minsize = stmt.expressions.minsize
                    maxsize = #stmt.expressions.expressions
                else
                    minsize = math.max(minsize,stmt.expressions.minsize)
                    maxsize = math.min(maxsize,#stmt.expressions.expressions)
                    if minsize > maxsize then
                        terra.reporterror(ctx,stmt,"returning a different length from previous return")
                    else
                        for i,exp in ipairs(stmt.expressions.expressions) do
                            if i <= maxsize then
                                return_types[i] = typemeet(exp,return_types[i],exp.type)
                            end
                        end
                    end
                end
            end
            while #return_types > maxsize do
                table.remove(return_types)
            end
            
        end
    end
    
    --now cast each return expression to the expected return type
    for _,stmt in ipairs(return_stmts) do
        insertcasts(return_types,stmt.expressions)
    end
    
    --we're done. build the typed tree for this function
    local typedtree = ftree:copy { body = result, parameters = typed_parameters, labels = labels, type = terra.types.functype(parameter_types,return_types) }
    
    dbprint(2,"TypedTree")
    dbprintraw(2,typedtree)
    
    return typedtree
end
--cache for lua functions called by terra, to prevent making multiple callback functions
terra.__wrappedluafunctions = {}

-- END TYPECHECKER

-- INCLUDEC

function terra.includecstring(code)
    return terra.registercfile(code,{"-I",".","-O3"})
end
function terra.includec(fname)
    return terra.includecstring("#include \""..fname.."\"\n")
end

function terra.includetableindex(tbl,name)    --this is called when a table returned from terra.includec doesn't contain an entry
    local v = getmetatable(tbl).errors[name]  --it is used to report why a function or type couldn't be included
    if v then
        error("includec: error importing symbol '"..name.."': "..v, 2)
    else
        error("includec: imported symbol '"..name.."' not found.",2)
    end
    return nil
end

-- GLOBAL MACROS
_G["sizeof"] = macro(function(ctx,tree,typ)
    return terra.newtree(tree,{ kind = terra.kinds.sizeof, oftype = typ:astype(ctx)})
end)
_G["vector"] = macro(function(ctx,tree,...)
    if terra.types.istype(ctx) then --vector used as a type constructor vector(int,3)
        return terra.types.vector(ctx,tree)
    end
    --otherwise this is a macro that constructs a vector literal
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return terra.newtree(tree,{ kind = terra.kinds.vectorconstructor, expressions = exps })
    
end)
_G["vectorof"] = macro(function(ctx,tree,typ,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return terra.newtree(tree,{ kind = terra.kinds.vectorconstructor, oftype = typ:astype(ctx), expressions = exps })
end)
_G["array"] = macro(function(ctx,tree,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return terra.newtree(tree, { kind = terra.kinds.arrayconstructor, expressions = exps })
end)
_G["arrayof"] = macro(function(ctx,tree,typ,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return terra.newtree(tree, { kind = terra.kinds.arrayconstructor, oftype = typ:astype(ctx), expressions = exps })
end)

_G["global"] = terra.global
_G["constant"] = terra.constant

terra.select = macro(function(ctx,tree,guard,a,b)
    return terra.newtree(tree, { kind = terra.kinds.operator, operator = terra.kinds.select, operands = terra.newlist{guard.tree,a.tree,b.tree}})
end)

local function annotatememory(arg,tbl)
    if arg.tree:is "typedexpressionlist" and #arg.tree.expressions > 0 then
        local e = arg.tree.expressions[1]
        if (e:is "operator" and e.operator == terra.kinds["@"]) or e:is "index" then
            return arg.tree:copy { expressions = terra.newlist { e:copy(tbl) } }
        end
    end
    error("expected a dereference operator")
end

terra.nontemporal = macro( function(ctx,tree,arg)
    return annotatememory(arg,{nontemporal = true})
end)

terra.aligned = macro( function(ctx,tree,arg,num)
    local n = num:asvalue()
    if type(n) ~= "number" then
        error("expected a number for alignment")
    end
    return annotatememory(arg,{alignment = n})
end)


-- END GLOBAL MACROS

-- DEBUG

function terra.printf(s,...)
    local function toformat(x)
        if type(x) ~= "number" and type(x) ~= "string" then
            return tostring(x) 
        else
            return x
        end
    end
    local strs = terra.newlist({...}):map(toformat)
    --print(debug.traceback())
    return io.write(tostring(s):format(unpack(strs)))
end

function terra.func:printpretty()
    for i,v in ipairs(self.variants) do
        v:compile()
        terra.printf("%s = ",v.name,v.type)
        v:printpretty()
    end
end
function terra.funcvariant:printpretty()
    self:compile()
    if not self.typedtree then
        terra.printf("<extern : %s>\n",self.type)
        return
    end
    local indent = 0
    local function enterblock()
        indent = indent + 1
    end
    local function leaveblock()
        indent = indent - 1
    end
    local function emit(...) terra.printf(...) end
    local function begin(...)
        for i = 1,indent do
            io.write("    ")
        end
        emit(...)
    end

    local function emitList(lst,begin,sep,finish,fn)
        emit(begin)
        if not fn then
            fn = function(e) emit(e) end
        end
        for i,k in ipairs(lst) do
            fn(k,i)
            if i ~= #lst then
                emit(sep)
            end
        end
        emit(finish)
    end

    local function emitType(t)
        emit(t)
    end

    local function emitParam(p)
        emit("%s : %s",p.name,p.type)
    end
    local emitStmt, emitExp,emitParamList

    function emitStmt(s)
        if s:is "block" then
            enterblock()
            local function emitStatList(lst) --nested statements (e.g. from quotes need "do" appended)
                for i,ss in ipairs(lst) do
                    if ss:is "block" then
                        begin("do\n")
                        enterblock()
                        emitStatList(ss.statements)
                        leaveblock()
                        begin("end\n")
                    else
                        emitStmt(ss)
                    end
                end
            end
            emitStatList(s.statements)
            leaveblock()
        elseif s:is "return" then
            begin("return ")
            emitParamList(s.expressions)
            emit("\n")
        elseif s:is "label" then
            begin("::%s::\n",s.labelname)
        elseif s:is "goto" then
            begin("goto %s\n",s.definition.labelname)
        elseif s:is "break" then
            begin("break\n")
        elseif s:is "while" then
            begin("while ")
            emitExp(s.condition)
            emit(" do\n")
            emitStmt(s.body)
            begin("end\n")
        elseif s:is "if" then
            for i,b in ipairs(s.branches) do
                if i == 1 then
                    begin("if ")
                else
                    begin("elseif ")
                end
                emitExp(b.condition)
                emit(" then\n")
                emitStmt(b.body)
            end
            begin("else\n")
            emitStmt(s.orelse)
            begin("end\n")
        elseif s:is "repeat" then
            begin("repeat\n")
            emitStmt(s.body)
            begin("until ")
            emitExp(s.condition)
            emit("\n")
        elseif s:is "defvar" then
            begin("var ")
            if s.isglobal then
                emit("{global} ")
            end
            emitList(s.variables,"",", ","",emitParam)
            if s.initializers then
                emit(" = ")
                emitParamList(s.initializers)
            end
            emit("\n")
        elseif s:is "assignment" then
            begin("")
            emitList(s.lhs,"",", ","",emitExp)
            emit(" = ")
            emitParamList(s.rhs)
            emit("\n")
        else
            begin("")
            emitExp(s)
            emit("\n")
        end
    end
    
    local function makeprectable(...)
        local lst = {...}
        local sz = #lst
        local tbl = {}
        for i = 1,#lst,2 do
            tbl[lst[i]] = lst[i+1]
        end
        return tbl
    end

    local prectable = makeprectable(
     "+",7,"-",7,"*",7,"/",8,"%",8,
     "^",11,"..",6,"<<",4,">>",4,
     "==",3,"<",3,"<=",3,
     "~=",3,">",3,">=",3,
     "and",2,"or",1,
     "@",9,"-",9,"&",9,"not",9,"select",12)
    
    local function getprec(e)
        if e:is "operator" then
            return prectable[terra.kinds[e.operator]]
        else
            return 12
        end
    end
    local function doparens(ref,e)
        if getprec(ref) > getprec(e) then
            emit("(")
            emitExp(e)
            emit(")")
        else
            emitExp(e)
        end
    end

    function emitExp(e)
        if e:is "var" then
            emit(e.name)
        elseif e:is "ltor" or e:is "rtol" then
            emitExp(e.expression)
        elseif e:is "operator" then
            local op = terra.kinds[e.operator]
            local function emitOperand(o)
                doparens(e,o)
            end
            if #e.operands == 1 then
                emit(op)
                emitOperand(e.operands[1])
            elseif #e.operands == 2 then
                emitOperand(e.operands[1])
                emit(" %s ",op)
                emitOperand(e.operands[2])
            elseif op == "select" then
                emit("terralib.select")
                emitList(e.operands,"(",", ",")",emitExp)
            else
                emit("<??operator??>")
            end
        elseif e:is "index" then
            doparens(e,e.value)
            emit("[")
            emitExp(e.index)
            emit("]")
        elseif e:is "literal" then
            if e.type:ispointer() and e.type.type:isfunction() then
                emit(e.value.name)
            elseif e.type:isintegral() then
                emit(e.stringvalue or "<int>")
            elseif type(e.value) == "string" then
                emit("%q",e.value)
            else
                emit("%s",e.value)
            end
        elseif e:is "luafunction" then
            emit("<luafunction>")
        elseif e:is "cast" then
            emit("[")
            emitType(e.to)
            emit("](")
            emitExp(e.expression)
            emit(")")

        elseif e:is "sizeof" then
            emit("sizeof(%s)",e.oftype)
        elseif e:is "apply" then
            doparens(e,e.value)
            emit("(")
            emitParamList(e.arguments)
            emit(")")
        elseif e:is "extractreturn" then
            emit("<extract%d>",e.index)
        elseif e:is "select" then
            doparens(e,e.value)
            emit(".")
            emit(e.field)
        elseif e:is "vectorconstructor" then
            emit("vector(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "arrayconstructor" then
            emit("array(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "constructor" then
            emit("{")
            local anon = 0
            local keys = e.type.entries:map(function(e) return e.key end)
            emitParamList(e.expressions,keys)
            emit("}")
        elseif e:is "constant" then
            if e.type:isprimitive() then
                emit(tonumber(e.value.object))
            else
                emit("<constant:",e.type,">")
            end
        else
            emit("<??"..terra.kinds[e.kind].."??>")
        end
    end

    function emitParamList(pl,keys)
        local function emitE(e,i)
            if keys and keys[i] then
                emit(keys[i])
                emit(" = ")
            end
            emitExp(e)
        end
        emitList(pl.expressions,"",", ","",emitE)
        if pl.funccall then
            emit(" {")
            emitExp(pl.funccall)
            emit("}")
        end
    end

    emit("terra")
    emitList(self.typedtree.parameters,"(",",",") : ",emitParam)
    emitList(self.type.returns,"{",", ","}",emitType)
    emit("\n")
    emitStmt(self.typedtree.body)
    emit("end\n")
end

-- END DEBUG

function terra.saveobj(filename,env,arguments)
    local cleanenv = {}
    for k,v in pairs(env) do
        if terra.isfunction(v) then
            v:compile({nojit = true})
            local variants = v:getvariants()
            if #variants > 1 then
                error("cannot create a C function from an overloaded terra function, "..k)
            end
            cleanenv[k] = variants[1]
        end
    end
    local isexe
    if filename:sub(-2) == ".o" then
        isexe = 0
    else
        isexe = 1
    end
    if not arguments then
        arguments = {}
    end
    return terra.saveobjimpl(filename,cleanenv,isexe,arguments)
end

terra.packages = {} --table of packages loaded using terralib.require()

function terra.require(name)
    if not terra.packages[name] then
        local file = name .. ".t"
        local fn, err = terra.loadfile(file)
        if not fn then
            error(err,0)
        end
        terra.packages[name] = { results = {fn()} }    
    end
    return unpack(terra.packages[name].results)
end
function terra.makeenvunstrict(env)
    if getmetatable(env) and getmetatable(env).__Idle_declared then
        return function(self,idx)
            return (Strict.isDeclared(idx,env) and env[idx]) or nil
        end
    else return env end
end

function terra.new(terratype,...)
    terratype:freeze()
    local typ = terratype:cstring()
    return ffi.new(typ,...)
end

function terra.cast(terratype,obj)
    terratype:freeze()
    local ctyp = terratype:cstring()
    if type(obj) == "function" then --functions are cached to avoid creating too many callback objects
        local fncache = terra.__wrappedluafunctions[obj]

        if not fncache then
            fncache = {}
            terra.__wrappedluafunctions[obj] = fncache
        end
        local cb = fncache[terratype]
        if not cb then
            cb = ffi.cast(ctyp,obj)
            fncache[terratype] = cb
        end
        return cb
    end
    return ffi.cast(ctyp,obj)
end

terra.constantobj = {}
terra.constantobj.__index = terra.constantobj

--c.object is the cdata value for this object
--string constants are handled specially since they should be treated as objects and not pointers
--in this case c.object is a string rather than a cdata object
--c.type is the terra type


function terra.isconstant(obj)
    return getmetatable(obj) == terra.constantobj
end

function terra.constant(a0,a1)
    if terra.types.istype(a0) then
        local c = setmetatable({ type = a0, object = a1 },terra.constantobj)
        --special handling for string literals
        if type(c.object) == "string" and c.type == rawstring then
            return c
        end

        --if the  object is not already cdata, we need to convert it
        if  type(c.object) ~= "cdata" or terra.typeof(c.object) ~= c.type then
            c.object = terra.cast(c.type,c.object)
        end
        return c
    else
        --try to infer the type, and if successful build the constant
        local init,typ = a0,nil
        if type(init) == "cdata" then
            typ = terra.typeof(init)
        elseif type(init) == "number" then
            typ = (math.floor(init) == init and int) or double
        elseif type(init) == "boolean" then
            typ = bool
        elseif type(init) == "string" then
            typ = rawstring
        else
            error("constant constructor requires explicit type for objects of type "..type(init))
        end
        return terra.constant(typ,init)
    end
end

function terra.typeof(obj)
    if type(obj) ~= "cdata" then
        error("cannot get the type of a non cdata object")
    end
    return terra.types.ctypetoterra[tostring(ffi.typeof(obj))]
end

terra.languageextension = {
    languages = terra.newlist();
    entrypoints = {}; --table mapping entry pointing tokens to the language that handles them
    tokentype = {}; --metatable for tokentype objects
    tokenkindtotoken = {}; --map from token's kind id (terra.kind.name), to the singleton table (terra.languageextension.name) 
}

function terra.loadlanguage(lang)
    local E = terra.languageextension
    if not lang or type(lang) ~= "table" then error("expected a table to define language") end
    lang.name = lang.name or "anonymous"
    local function haslist(field,typ)
        if not lang[field] then 
            error(field .. " expected to be list of "..typ)
        end
        for i,k in ipairs(lang[field]) do
            if type(k) ~= typ then
                error(field .. " expected to be list of "..typ.." but found "..type(k))
            end
        end
    end
    haslist("keywords","string")
    haslist("entrypoints","string")
    
    for i,e in ipairs(lang.entrypoints) do
        if E.entrypoints[e] then
            error(("language %s uses entrypoint %s already defined by language %s"):format(lang.name,e,E.entrypoints[e].name))
        end
        E.entrypoints[e] = lang
    end
    lang.keywordtable = {} --keyword => true
    for i,k in ipairs(lang.keywords) do
        lang.keywordtable[k] = true
    end
    for i,k in ipairs(lang.entrypoints) do
        lang.keywordtable[k] = true
    end

    E.languages:insert(lang)
end

function terra.languageextension.tokentype:__tostring()
    return self.name
end

do
    local special = { "name", "string", "number", "eof", "default" }
    --note: default is not a tokentype but can be used in libraries to match
    --a token that is not another type
    for i,k in ipairs(special) do
        local name = "<" .. k .. ">"
        local tbl = setmetatable({
            name = name }, terra.languageextension.tokentype )
        terra.languageextension[k] = tbl
        local kind = terra.kinds[name]
        if kind then
            terra.languageextension.tokenkindtotoken[kind] = tbl
        end
    end
end

function terra.runlanguage(lang,cur,lookahead,next,luaexpr,source,isstatement,islocal)
    local lex = {}
    
    lex.name = terra.languageextension.name
    lex.string = terra.languageextension.string
    lex.number = terra.languageextension.number
    lex.eof = terra.languageextension.eof
    lex.default = terra.languageextension.default

    lex._references = terra.newlist()
    lex.source = source

    local function maketoken(tok)
        if type(tok.type) ~= "string" then
            tok.type = terra.languageextension.tokenkindtotoken[tok.type]
            assert(type(tok.type) == "table") 
        end
        return tok
    end
    function lex:cur()
        self._cur = self._cur or maketoken(cur())
        return self._cur
    end
    function lex:lookahead()
        self._lookahead = self._lookahead or maketoken(lookahead())
        return self._lookahead
    end
    function lex:next()
        local v = self:cur()
        self._cur,self._lookahead = nil,nil
        next()
        return v
    end
    function lex:luaexpr()
        self._cur,self._lookahead = nil,nil --parsing an expression invalidates our lua representations 
        local expr = luaexpr()
        return function(env)
            setfenv(expr,env)
            return expr()
        end
    end

    function lex:ref(name)
        if type(name) ~= "string" then
            error("references must be identifiers")
        end
        self._references:insert(name)
    end

    function lex:typetostring(name)
        if type(name) == "string" then
            return name
        else
            return terra.kinds[name]
        end
    end
    
    function lex:nextif(typ)
        if self:cur().type == typ then
            return self:next()
        else return false end
    end
    function lex:expect(typ)
        local n = self:nextif(typ)
        if not n then
            self:errorexpected(tostring(typ))
        end
        return n
    end
    function lex:matches(typ)
        return self:cur().type == typ
    end
    function lex:lookaheadmatches(typ)
        return self:lookahead().type == typ
    end
    function lex:error(msg)
        error(msg,0) --,0 suppresses the addition of line number information, which we do not want here since
                     --this is a user-caused errors
    end
    function lex:errorexpected(what)
        self:error(what.." expected")
    end
    function lex:expectmatch(typ,openingtokentype,linenumber)
       local n = self:nextif(typ)
        if not n then
            if self:cur().linenumber == linenumber then
                lex:errorexpected(tostring(typ))
            else
                lex:error(string.format("%s expected (to close %s at line %d)",tostring(typ),tostring(openingtokentype),linenumber))
            end
        end
        return n
    end

    local constructor,names
    if isstatement and islocal and lang.localstatement then
        constructor,names = lang:localstatement(lex)
    elseif isstatement and not islocal and lang.statement then
        constructor,names = lang:statement(lex)
    elseif not islocal and lang.expression then
        constructor = lang:expression(lex)
    else
        lex:error("unexpected token")
    end
    
    if not constructor or type(constructor) ~= "function" then
        error("expected language to return a construction function")
    end

    local function isidentifier(str)
        local b,e = string.find(str,"[%a_][%a%d_]*")
        return b == 1 and e == string.len(str)
    end

    --fixup names    

    if not names then 
        names = {}
    end

    if type(names) ~= "table" then
        error("names returned from constructor must be a table")
    end

    if islocal and #names == 0 then
        error("local statements must define at least one name")
    end

    for i = 1,#names do
        if type(names[i]) ~= "table" then
            names[i] = { names[i] }
        end
        local name = names[i]
        if #name == 0 then
            error("name must contain at least one element")
        end
        for i,c in ipairs(name) do
            if type(c) ~= "string" or not isidentifier(c) then
                error("name component must be an identifier")
            end
            if islocal and i > 1 then
                error("local names must have exactly one element")
            end
        end
    end

    return constructor,names,lex._references
end

_G["terralib"] = terra --terra code can't use "terra" because it is a keyword
--io.write("done\n")
