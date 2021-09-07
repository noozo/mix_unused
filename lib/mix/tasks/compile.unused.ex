defmodule Mix.Tasks.Compile.Unused do
  use Mix.Task.Compiler

  @shortdoc "Find unused public functions"

  @moduledoc """
  Compile project and find uncalled public functions.

  ### Warning

  This isn't perfect solution and this will not find dynamic calls in form of:

      apply(mod, func, args)

  So this mean that, for example, if you have custom `child_spec/1` definition
  then this will return such function as unused even when you are using that
  indirectly in your supervisor.

  ## Configuration

  You can define used functions by adding `mfa` in `unused: [ignored: [⋯]]`
  in your project configuration:

      def project do
        [
          # ⋯
          unused: [
            ignore: [
              {MyApp.Foo, :child_spec, 1}
            ]
          ],
          # ⋯
        ]
      end

  ## Options

  - `severity` - severity of the reported messages, defaults to `hint`.
    Other allowed levels are `information`, `warning`, and `error`.
  """

  @recursive true

  # These are functions generated by Elixir and Erlang, this list probably
  # should not grow.
  @built_ins [
    __info__: 1,
    __struct__: 0,
    __struct__: 1,
    __impl__: 1,
    module_info: 0,
    module_info: 1,
    behaviour_info: 1
  ]

  @manifest "unused.manifest"

  @options [
    severity: :string
  ]

  alias MixUnused.Tracer

  @impl true
  def run(argv) do
    {opts, _rest, _other} = OptionParser.parse(argv, strict: @options)
    {:ok, _pid} = Tracer.start_link()

    [manifest] = manifests()

    tracers = Code.get_compiler_option(:tracers)
    Mix.Task.Compiler.after_compiler(:app, &after_compiler(&1, tracers, opts, manifest))
    Code.put_compiler_option(:tracers, [Tracer | tracers])

    {:ok, []}
  end

  @impl true
  def manifests do
    [Path.join(Mix.Project.manifest_path(), @manifest)]
  end

  @impl true
  def clean do
    Enum.each(manifests(), &File.rm/1)
  end

  defp after_compiler({status, diagnostics}, tracers, opts, manifest) do
    # Cleanup tracers after compilation
    Code.put_compiler_option(:tracers, tracers)

    cache =
      case File.read(manifest) do
        {:ok, data} -> :erlang.binary_to_term(data)
        _ -> %{}
      end

    data = Map.merge(cache, Tracer.get_data())

    calls = Enum.flat_map(data, fn {_key, value} -> value end)

    File.write!(manifest, :erlang.term_to_binary(data))

    severity = Keyword.get(opts, :severity, "hint") |> severity()

    unused =
      Mix.Project.config()[:app]
      |> all_functions()
      |> Map.drop(calls)
      |> filter_ignored()
      |> Enum.sort()

    :ok = Tracer.stop()

    messages =
      for {{m, f, a}, meta} <- unused do
        %Mix.Task.Compiler.Diagnostic{
          compiler_name: "unused",
          message: "#{inspect(m)}.#{f}/#{a} is unused",
          severity: severity,
          # TODO: Find a way to extract position of the function
          position: nil,
          file: meta.file
        }
        |> print_diagnostic()
      end

    {status, messages ++ diagnostics}
  end

  defp all_functions(app) do
    _ = Application.unload(app)
    :ok = Application.load(app)

    # Check exported functions without loading modules as this could cause
    # unexpected behaviours in case of `on_load` callbacks
    for mod <- Application.spec(app, :modules),
        path = :code.which(mod),
        is_list(path),
        {:ok, {^mod, data}} = :beam_lib.chunks(path, [:exports, :attributes, :compile_info]),
        callbacks =
          data[:attributes]
          |> Keyword.get(:behaviour, [])
          |> callbacks(),
        source = Keyword.get(data[:compile_info], :source, "nofile") |> to_string(),
        {name, arity} <- data[:exports],
        {name, arity} not in @built_ins,
        {name, arity} not in callbacks,
        into: %{},
        do: {{mod, name, arity}, %{file: source}}
  end

  defp callbacks(behaviours) do
    # We need to load behaviours as there is no other way to get list of
    # callbacks than to call `behaviour_info/1`
    Enum.flat_map(behaviours, & &1.behaviour_info(:callbacks))
  end

  defp filter_ignored(functions) do
    filters =
      Mix.Project.config()
      |> Keyword.get(:unused, [])
      |> Keyword.get(:ignore, [])
      |> Enum.map(fn
        {_m, _f, _a} = entry -> entry
        {m, f} -> {m, f, :_}
        m -> {m, :_, :_}
      end)

    Enum.reject(functions, fn {func, _} ->
      Enum.any?(filters, &MixUnused.Utils.mfa_match?(&1, func))
    end)
  end

  defp severity("hint"), do: :hint
  defp severity("info"), do: :information
  defp severity("information"), do: :information
  defp severity("warn"), do: :warning
  defp severity("warning"), do: :warning
  defp severity("error"), do: :error

  defp print_diagnostic(diag) do
    Mix.shell().info([level(diag.severity), diag.message])

    diag
  end

  defp level(level), do: [:bright, color(level), "#{level}: ", :reset]

  defp color(:error), do: :red
  defp color(:warning), do: :yellow
  defp color(_), do: :blue
end
