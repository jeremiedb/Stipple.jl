module ReactiveTools

using Stipple
using MacroTools
using MacroTools: postwalk
using OrderedCollections
import Genie
import Stipple: deletemode!, parse_expression!, init_storage

export @readonly, @private, @in, @out, @jsfn, @readonly!, @private!, @in!, @out!, @jsfn!
export @mix_in, @clear, @vars, @add_vars
export @page, @rstruct, @type, @handlers, @init, @model, @onchange, @onchangeany, @onbutton
export DEFAULT_LAYOUT, Page

const REACTIVE_STORAGE = LittleDict{Module,LittleDict{Symbol,Expr}}()
const TYPES = LittleDict{Module,Union{<:DataType,Nothing}}()

function DEFAULT_LAYOUT(; title::String = "Genie App")
  """
  <!DOCTYPE html>
  <html lang="en">
  
  <head>
    <link href="https://fonts.googleapis.com/css?family=Roboto:100,300,400,500,700,900|Material+Icons" rel="stylesheet" type="text/css">
    <link href="https://cdn.jsdelivr.net/npm/quasar@2.11.5/dist/quasar.prod.css" rel="stylesheet" type="text/css">
  </head>
  
  <body>
    <div id="q-app">
      <q-layout view="hHh lpR fFf">
  
        <q-header elevated class="bg-primary text-white">
          <q-toolbar>
            <q-toolbar-title>
              <q-avatar>
                <img src="https://cdn.quasar.dev/logo-v2/svg/logo-mono-white.svg">
              </q-avatar>
              Title
            </q-toolbar-title>
          </q-toolbar>
        </q-header>
    
        <q-page-container>
          <router-view />
        </q-page-container>
    
        <q-footer elevated class="bg-grey-8 text-white">
          <q-toolbar>
            <q-toolbar-title>
              <q-avatar>
                <img src="https://cdn.quasar.dev/logo-v2/svg/logo-mono-white.svg">
              </q-avatar>
              Title
            </q-toolbar-title>
          </q-toolbar>
        </q-footer>
    
      </q-layout>
    </div>
  
    <script src="https://cdn.jsdelivr.net/npm/vue@3/dist/vue.global.prod.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/quasar@2.11.5/dist/quasar.umd.prod.js"></script>
  
    <script>
      const app = Vue.createApp({
        setup () {
          return {}
        }
      })
  
      app.use(Quasar)
      app.mount('#q-app')
    </script>
  </body>
  
  </html>
"""
end

function default_struct_name(m::Module)
  "$(m)_ReactiveModel"
end

function Stipple.init_storage(m::Module)
  (m == @__MODULE__) && return nothing 
  haskey(REACTIVE_STORAGE, m) || (REACTIVE_STORAGE[m] = Stipple.init_storage())
  haskey(TYPES, m) || (TYPES[m] = nothing)
end

function Stipple.setmode!(expr::Expr, mode::Int, fieldnames::Symbol...)
  fieldname in [Stipple.CHANNELFIELDNAME, :_modes] && return

  d = eval(expr.args[2])
  for fieldname in fieldnames
    mode == PUBLIC ? delete!(d, fieldname) : d[fieldname] = mode
  end
  expr.args[2] = QuoteNode(d)
end

#===#

function clear_type(m::Module)
  TYPES[m] = nothing
end

function delete_bindings!(m::Module)
  clear_type(m)
  delete!(REACTIVE_STORAGE, m)
end

function bindings(m)
  init_storage(m)
  REACTIVE_STORAGE[m]
end

#===#

macro clear()
  delete_bindings!(__module__)
end

macro clear(args...)
  haskey(REACTIVE_STORAGE, __module__) || return
  for arg in args
    arg in [Stipple.CHANNELFIELDNAME, :_modes] && continue
    delete!(REACTIVE_STORAGE[__module__], arg)
  end
  deletemode!(REACTIVE_STORAGE[__module__][:_modes], args...)

  update_storage(__module__)

  REACTIVE_STORAGE[__module__]
end

import Stipple.@type
macro type()  
  Stipple.init_storage(__module__)
  type = if TYPES[__module__] !== nothing
    TYPES[__module__]
  else
    modelname = Symbol(default_struct_name(__module__))
    storage = REACTIVE_STORAGE[__module__]
    TYPES[__module__] = @eval(__module__, Stipple.@type($modelname, $storage))
  end

  esc(:($type))
end

function update_storage(m::Module)
  clear_type(m)
  # isempty(Stipple.Pages._pages) && return
  # instance = @eval m Stipple.@type()
  # for p in Stipple.Pages._pages
  #   p.context == m && (p.model = instance)
  # end
end

import Stipple: @vars, @add_vars

macro vars(expr)
  init_storage(__module__)
  
  REACTIVE_STORAGE[__module__] = @eval(__module__, Stipple.@var_storage($expr))

  update_storage(__module__)
end

macro add_vars(expr)
  init_storage(__module__)
  REACTIVE_STORAGE[__module__] = Stipple.merge_storage(REACTIVE_STORAGE[__module__], @eval(__module__, Stipple.@var_storage($expr)))

  update_storage(__module__)
end

macro model()
  esc(quote
    ReactiveTools.@type() |> Base.invokelatest
  end)
end

#===#

function binding(expr::Symbol, m::Module, @nospecialize(mode::Any = nothing); source = nothing, reactive = true)
  binding(:($expr = $expr), m, mode; source, reactive)
end

function binding(expr::Expr, m::Module, @nospecialize(mode::Any = nothing); source = nothing, reactive = true)
  (m == @__MODULE__) && return nothing

  intmode = @eval Stipple $mode
  init_storage(m)

  var, field_expr = parse_expression!(expr, reactive ? mode : nothing, source, m)
  REACTIVE_STORAGE[m][var] = field_expr

  reactive || setmode!(REACTIVE_STORAGE[m][:_modes], intmode, var)
  reactive && setmode!(REACTIVE_STORAGE[m][:_modes], PUBLIC, var)

  # remove cached type and instance, update pages
  update_storage(m)
end

# this macro needs to run in a macro where `expr`is already defined
macro report_val()
  quote
    val = expr isa Symbol ? expr : expr.args[2]
    issymbol = val isa Symbol
    :(if $issymbol
      if isdefined(@__MODULE__, $(QuoteNode(val)))
        $val
      else
        @info(string("Warning: Variable '", $(QuoteNode(val)), "' not yet defined"))
      end
    else
      Stipple.Observables.to_value($val)
    end) |> esc
  end |> esc
end

# this macro needs to run in a macro where `expr`is already defined
macro define_var()
  quote
    ( expr isa Symbol || expr.head !== :(=) ) && return expr
    var = expr.args[1] isa Symbol ? expr.args[1] : expr.args[1].args[1]
    new_expr = :($var = Stipple.Observables.to_value($(expr.args[2])))
    esc(:($new_expr))
  end |> esc
end

# works with
# @in a = 2
# @in a::Vector = [1, 2, 3]
# @in a::Vector{Int} = [1, 2, 3]
macro in(expr)
  binding(copy(expr), __module__, :PUBLIC; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro in(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@in($expr)))
  binding(copy(expr), __module__, :PUBLIC; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro in!(expr)
  binding(expr, __module__, :PUBLIC; source = __source__)
  @report_val()
end

macro in!(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@in($expr)))
  binding(expr, __module__, :PUBLIC; source = __source__, reactive = false)
  @report_val()
end

macro out(expr)
  binding(copy(expr), __module__, :READONLY; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro out(flag, expr)
  flag != :non_reactive && return esc(:(@out($expr)))

  binding(copy(expr), __module__, :READONLY; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro out!(expr)
  binding(expr, __module__, :READONLY; source = __source__)
  @report_val()
end

macro out!(flag, expr)
  flag != :non_reactive && return esc(:(@out($expr)))

  binding(expr, __module__, :READONLY; source = __source__, reactive = false)
  @report_val()
end

macro readonly(expr)
  esc(:(ReactiveTools.@out($expr)))
end

macro readonly(flag, expr)
  esc(:(ReactiveTools.@out($flag, $expr)))
end

macro readonly!(expr)
  esc(:(ReactiveTools.@out!($expr)))
end

macro readonly!(flag, expr)
  esc(:(ReactiveTools.@out!($flag, $expr)))
end

macro private(expr)
  binding(copy(expr), __module__, :PRIVATE; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro private(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@private($expr)))

  binding(copy(expr), __module__, :PRIVATE; source = __source__, reactive = false)
  # @define_var()
  esc(:($expr))
end

macro private!(expr)
  binding(expr, __module__, :PRIVATE; source = __source__)
  @report_val()
end

macro private!(flag, expr)
  flag != :non_reactive && return esc(:(ReactiveTools.@private($expr)))

  binding(expr, __module__, :PRIVATE; source = __source__, reactive = false)
  @report_val()
end

macro jsfn(expr)
  binding(copy(expr), __module__, :JSFUNCTION; source = __source__)
  # @define_var()
  esc(:($expr))
end

macro jsfn!(expr)
  binding(expr, __module__, :JSFUNCTION; source = __source__)
  @report_val()
end

macro mix_in(expr, prefix = "", postfix = "")
  init_storage(__module__)

  if hasproperty(expr, :head) && expr.head == :(::)
      prefix = string(expr.args[1])
      expr = expr.args[2]
  end

  x = Core.eval(__module__, expr)
  pre = Core.eval(__module__, prefix)
  post = Core.eval(__module__, postfix)

  T = x isa DataType ? x : typeof(x)
  mix = x isa DataType ? x() : x
  values = getfield.(Ref(mix), fieldnames(T))
  ff = Symbol.(pre, fieldnames(T), post)
  for (f, type, v) in zip(ff, fieldtypes(T), values)
      v_copy = Stipple._deepcopy(v)
      expr = :($f::$type = Stipple._deepcopy(v))
      REACTIVE_STORAGE[__module__][f] = v isa Symbol ? :($f::$type = $(QuoteNode(v))) : :($f::$type = $v_copy)
  end

  update_storage(__module__)
  esc(Stipple.Observables.to_value.(values))
end

#===#

macro init(modeltype)
  quote
    local initfn =  if isdefined($__module__, :init_from_storage)
                      $__module__.init_from_storage
                    else
                      $__module__.init
                    end
    local handlersfn =  if isdefined($__module__, :__GF_AUTO_HANDLERS__)
                          $__module__.__GF_AUTO_HANDLERS__
                        else
                          identity
                        end

    instance = $modeltype |> initfn |> handlersfn
    for p in Stipple.Pages._pages
      p.context == $__module__ && (p.model = instance)
    end
    instance
  end |> esc
end

macro init()
  quote
    let type = @type
      @init(type)
    end
  end |> esc
end

macro handlers(expr)
  quote
    isdefined(@__MODULE__, :__HANDLERS__) || @eval const __HANDLERS__ = Stipple.Observables.ObserverFunction[]

    function __GF_AUTO_HANDLERS__(__model__)
      empty!(__HANDLERS__)

      $expr

      return __model__
    end
  end |> esc
end

macro process_handler_input()
  quote
    known_vars = push!(Stipple.ReactiveTools.REACTIVE_STORAGE[__module__] |> keys |> collect, :isready, :isprocessing) # add mixins

    if isa(var, Symbol) && in(var, known_vars)
      var = :(__model__.$var)
    else
      error("Unknown binding $var")
    end

    expr = postwalk(x -> isa(x, Symbol) && in(x, known_vars) ? :(__model__.$x[]) : x, expr)
  end |> esc
end

macro process_handler_expr()
  quote
    known_vars = push!(Stipple.ReactiveTools.REACTIVE_STORAGE[__module__] |> keys |> collect, :isready, :isprocessing) # add mixins
    expr = postwalk(x -> isa(x, Symbol) && in(x, known_vars) ? :(__model__.$x[]) : x, expr)
  end |> esc
end

macro onchange(var, expr)
  @process_handler_input()

  quote
    push!(__HANDLERS__, (
      on($var) do __value__
        $expr
      end
      )
    )
  end |> esc
end

macro onchangeany(vars, expr)
  known_vars = push!(Stipple.ReactiveTools.REACTIVE_STORAGE[__module__] |> keys |> collect, :isready, :isprocessing) # add mixins

  va = postwalk(x -> isa(x, Symbol) && in(x, known_vars) ? :(__model__.$x) : x, vars)
  exp = postwalk(x -> isa(x, Symbol) && in(x, known_vars) ? :(__model__.$x[]) : x, expr)

  quote
    push!(__HANDLERS__, (
      onany($va...) do (__values__...)
        $exp
      end
      )...
    )
  end |> esc
end

macro onbutton(var, expr)
  @process_handler_input()

  quote
    push!(__HANDLERS__, (
      onbutton($var) do __value__
        $expr
      end
      )
    )
  end |> esc
end

#===#

macro page(url, view, layout, model, context)
  quote
    Stipple.Pages.Page( $url;
                        view = $view,
                        layout = $layout,
                        model = $model,
                        context = $context)
  end |> esc
end

macro page(url, view, layout, model)
  :(@page($url, $view, $layout, $model, $__module__)) |> esc
end

macro page(url, view, layout)
  :(@page($url, $view, $layout, () -> @eval($__module__, @init()))) |> esc
end

macro page(url, view)
  :(@page($url, $view, Stipple.ReactiveTools.DEFAULT_LAYOUT())) |> esc
end

# macros for model-specific js functions on the front-end (see Vue.js docs)

export @methods, @watch, @computed, @created, @mounted, @event, @client_data, @add_client_data

macro methods(expr)
  esc(quote
    let M = @type
      Stipple.js_methods(::M) = $expr
    end
  end)
end

macro watch(expr)
  esc(quote
    let M = @type
      Stipple.js_watch(::M) = $expr
    end
  end)
end

macro computed(expr)
  esc(quote
    let M = @type
      Stipple.js_computed(::M) = $expr
    end
  end)
end

macro created(expr)
  esc(quote
    let M = @type
      Stipple.js_created(::M) = $expr
    end
  end)
end

macro mounted(expr)
  esc(quote
    let M = @type
      Stipple.js_mounted(::M) = $expr
    end
  end)
end

macro event(event, expr)
  @process_handler_expr()
  esc(quote
    let M = @type, T = $(event isa QuoteNode ? event : QuoteNode(event))
      function Base.notify(__model__::M, ::Val{T}, @nospecialize(event))
        $expr
      end
    end
  end)
end

macro client_data(expr)
  if expr.head != :block
    expr = quote $expr end
  end

  output = :(Stipple.client_data())
  for e in expr.args
    e isa LineNumberNode && continue
    e.head = :kw
    push!(output.args, e)
  end

  esc(quote
    let M = @type
      Stipple.client_data(::M) = $output
    end
  end)
end

macro add_client_data(expr)
  if expr.head != :block
    expr = quote $expr end
  end

  output = :(Stipple.client_data())
  for e in expr.args
    e isa LineNumberNode && continue
    e.head = :kw
    push!(output.args, e)
  end

  esc(quote
    let M = @type
      cd_old = Stipple.client_data(M())
      cd_new = $output
      Stipple.client_data(::M) = merge(d1, d2)
    end
  end)
end

end