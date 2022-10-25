module ReactiveTools

using Stipple
using MacroTools
using MacroTools: postwalk
using OrderedCollections
import Genie

export @binding, @readonly, @private, @in, @out, @value, @jsfn
export @page, @rstruct, @type, @handlers, @init, @model, @onchange, @onchangeany, @onbutton
export DEFAULT_LAYOUT, Page

const REACTIVE_STORAGE = LittleDict{Module,LittleDict{Symbol,Expr}}()
const TYPES = LittleDict{Module,Union{<:DataType,Nothing}}()

function DEFAULT_LAYOUT(; title::String = "Genie App")
  """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <% Stipple.sesstoken() %>
    <title>$title</title>
    <% if isfile(joinpath(Genie.config.server_document_root, "css", "genieapp.css")) %>
    <link rel='stylesheet' href='/css/genieapp.css'>
    <% else %>
    <% end %>
    <% if isfile(joinpath(Genie.config.server_document_root, "css", "autogenerated.css")) %>
    <link rel='stylesheet' href='/css/autogenerated.css'>
    <% else %>
    <% end %>
    <style>
      ._genie_logo {
        background:url('/stipple.jl/master/assets/img/genie-logo.img') no-repeat;background-size:40px;
        padding-top:22px;padding-right:10px;color:transparent;font-size:9pt;
      ._genie .row .col-12 { width:50%;margin:auto; }
      }
    </style>
  </head>
  <body>
    <div class='container'>
      <div class='row'>
        <div class='col-12'>
          <% page(model, partial = true, v__cloak = true, [@yield], @iif(:isready)) %>
        </div>
      </div>
    </div>
    <% if isfile(joinpath(Genie.config.server_document_root, "js", "genieapp.js")) %>
    <script src='/js/genieapp.js'></script>
    <% else %>
    <% end %>
    <footer class='_genie container'>
      <div class='row'>
        <div class='col-12'>
          <p class='text-muted credit' style='text-align:center;color:#8d99ae;'>Built with
            <a href='https://genieframework.com' target='_blank' class='_genie_logo' ref='nofollow'>Genie</a>
          </p>
        </div>
      </div>
    </footer>
  </body>
</html>
"""
end

function default_struct_name(m::Module)
  "$(m)_ReactiveModel"
end

function init_storage(m::Module)
  (m == @__MODULE__) && return nothing

  haskey(REACTIVE_STORAGE, m) || (REACTIVE_STORAGE[m] = LittleDict{Symbol,Expr}())
  haskey(TYPES, m) || (TYPES[m] = nothing)

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

macro rstruct()
  init_storage(__module__)

  """
  @reactive! mutable struct $(default_struct_name(__module__)) <: ReactiveModel
    $(join(REACTIVE_STORAGE[__module__] |> values |> collect, "\n"))
  end
  """ |> Meta.parse |> esc
end

macro type()
  init_storage(__module__)

  """
  if Stipple.ReactiveTools.TYPES[@__MODULE__] !== nothing
    ReactiveTools.TYPES[@__MODULE__]
  else
    ReactiveTools.TYPES[@__MODULE__] = @eval ReactiveTools.@rstruct()
  end
  """ |> Meta.parse |> esc
end

macro model()
  init_storage(__module__)

  :(@type() |> Base.invokelatest)
end

#===#

function find_assignment(expr)
  assignment = nothing

  if isa(expr, Expr) && !contains(string(expr.head), "=")
    for arg in expr.args
      assignment = if isa(arg, Expr)
        find_assignment(arg)
      end
    end
  elseif isa(expr, Expr) && contains(string(expr.head), "=")
    assignment = expr
  else
    assignment = nothing
  end

  assignment
end

function parse_expression(expr::Expr, opts::String = "", typename::String = "Stipple.Reactive", source = nothing)
  expr = find_assignment(expr)

  (isa(expr, Expr) && contains(string(expr.head), "=")) ||
    error("Invalid binding expression -- use it with variables assignment ex `@binding a = 2`")

  var = expr.args[1]
  rtype = ""

  if ! isempty(opts)
    rtype = "::R"
    typename = "R"
  end

  if isa(var, Expr) && var.head == Symbol("::")
    rtype = "::R{$(var.args[2])}"
    var = var.args[1]
    typename = "R"
  end

  op = expr.head

  source = (source !== nothing ? "\"$(strip(replace(replace(string(source), "#="=>""), "=#"=>"")))\"" : "")
  if Sys.iswindows()
    source = replace(source, "\\"=>"\\\\")
  end

  val = expr.args[2]
  isa(val, AbstractString) && (val = "\"$val\"")
  field = "$var$rtype $op $(typename)(($(val))$(opts),false,false,$source)"

  var, MacroTools.unblock(Meta.parse(field))
end

function binding(expr::Symbol, m::Module, opts::String = "", typename::String = "Stipple.Reactive"; source = nothing)
  binding(:($expr = $expr), m, opts, typename; source)
end

function binding(expr::Expr, m::Module, opts::String = "", typename::String = "Stipple.Reactive"; source = nothing)
  (m == @__MODULE__) && return nothing

  init_storage(m)

  var, field_expr = parse_expression(expr, opts, typename, source)
  REACTIVE_STORAGE[m][var] = field_expr

  # remove cached type and instance
  clear_type(m)

  instance = @eval m @type()
  for p in Stipple.Pages._pages
    p.context == m && (p.model = instance)
  end
end

# works with
# @binding a = 2
# @binding const a = 2
# @binding const a::Int = 24
# @binding a::Vector = [1, 2, 3]
# @binding a::Vector{Int} = [1, 2, 3]
macro in(expr)
  binding(expr, __module__, ", PUBLIC"; source = __source__)
  esc(expr)
end

macro out(expr)
  binding(expr, __module__, ", READONLY"; source = __source__)
  esc(expr)
end

macro readonly(expr)
  @out(expr) |> esc
end

macro private(expr)
  binding(expr, __module__, ", PRIVATE"; source = __source__)
  esc(expr)
end

macro jsfn(expr)
  binding(expr, __module__, ", JSFUNCTION"; source = __source__)
  esc(expr)
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
    @init(@type())
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
  :(@page($url, $view, $layout, () -> @init, $__module__)) |> esc
end

macro page(url, view, layout)
  :(@page($url, $view, $layout, () -> @init)) |> esc
end

macro page(url, view)
  :(@page($url, $view, Stipple.ReactiveTools.DEFAULT_LAYOUT())) |> esc
end



end