#!/usr/bin/julia

__precompile__(true)

module FunctionWrappers

# Used to bypass NULL check
@inline function assume(v::Bool)
    Base.llvmcall(("declare void @llvm.assume(i1)",
                   """
                   %v = trunc i8 %0 to i1
                   call void @llvm.assume(i1 %v)
                   ret void
                   """), Void, Tuple{Bool}, v)
end

# Convert return type and generates cfunction signatures
Base.@pure map_argtype(T) = (isbits(T) || T === Any) ? T : Ref{T}
Base.@pure get_cfunc_argtype(Obj, Args) =
    Tuple{Ref{Obj}, (map_argtype(Arg) for Arg in Args.parameters)...}

# Call wrapper since `cfunction` does not support non-function
# or closures
immutable CallWrapper{Ret} <: Function
end
(::CallWrapper{Ret}){Ret}(f, args...)::Ret = f(args...)

# Specialized wrapper for
for nargs in 0:128
    @eval (::CallWrapper{Ret}){Ret}(f, $((Symbol("arg", i) for i in 1:nargs)...))::Ret =
        f($((Symbol("arg", i) for i in 1:nargs)...))
end

type FunctionWrapper{Ret,Args<:Tuple}
    ptr::Ptr{Void}
    objptr::Ptr{Void}
    obj
    objT
    function FunctionWrapper{objT}(obj::objT)
        objref = Base.cconvert(Ref{objT}, obj)
        new(cfunction(CallWrapper{Ret}(), map_argtype(Ret),
                      get_cfunc_argtype(objT, Args)),
            Base.unsafe_convert(Ref{objT}, objref), objref, objT)
    end
    FunctionWrapper(obj::FunctionWrapper{Ret,Args}) = obj
end

Base.convert{T<:FunctionWrapper}(::Type{T}, obj) = T(obj)

@noinline function reinit_wrapper{Ret,Args}(f::FunctionWrapper{Ret,Args})
    objref = f.obj
    objT = f.objT
    ptr = cfunction(CallWrapper{Ret}(), map_argtype(Ret),
                    get_cfunc_argtype(objT, Args))
    f.ptr = ptr
    f.objptr = Base.unsafe_convert(Ref{objT}, objref)
    return ptr
end

@generated function do_ccall{Ret,Args}(f::FunctionWrapper{Ret,Args}, args::Args)
    # Has to be generated since the arguments type of `ccall` does not allow
    # anything other than tuple (i.e. `@pure` function doesn't work).
    quote
        $(Expr(:meta, :inline))
        ptr = f.ptr
        if ptr == C_NULL
            # For precompile support
            ptr = reinit_wrapper(f)
        end
        assume(ptr != C_NULL)
        objptr = f.objptr
        ccall(ptr, $(map_argtype(Ret)),
              (Ptr{Void}, $((map_argtype(Arg) for Arg in Args.parameters)...)),
              objptr, $((:(args[$i]) for i in 1:length(Args.parameters))...))
    end
end

@inline (f::FunctionWrapper)(args...) = do_ccall(f, args)

# Testing only
const identityAnyAny = FunctionWrapper{Any,Tuple{Any}}(identity)

end
