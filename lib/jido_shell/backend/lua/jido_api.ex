defmodule Jido.Shell.Backend.Lua.JidoApi do
  @moduledoc """
  Lua API bridge exposing registered Jido shell commands under `jido.*`.

  Functions in this module run as normal Elixir code from inside the Lua VM.
  They must keep the sandbox boundary intact by routing all shell behavior
  through `Jido.Shell.CommandRunner`.
  """

  use Lua.API, scope: "jido"

  alias Jido.Shell.CommandRunner
  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession.State

  @context_key :jido_shell_context

  @commands ~w(echo pwd ls cat cd mkdir write sleep seq env rm cp)

  def context_key, do: @context_key

  def install_globals(%Lua{} = lua) do
    Lua.set!(lua, [:print], fn args, state -> print(args, state) end)
  end

  @variadic true
  deflua echo(args), state do
    dispatch("echo", args, state)
  end

  @variadic true
  deflua pwd(args), state do
    dispatch("pwd", args, state)
  end

  @variadic true
  deflua ls(args), state do
    dispatch("ls", args, state)
  end

  @variadic true
  deflua cat(args), state do
    dispatch("cat", args, state)
  end

  @variadic true
  deflua cd(args), state do
    dispatch("cd", args, state)
  end

  @variadic true
  deflua mkdir(args), state do
    dispatch("mkdir", args, state)
  end

  @variadic true
  deflua write(args), state do
    dispatch("write", args, state)
  end

  @variadic true
  deflua sleep(args), state do
    dispatch("sleep", args, state)
  end

  @variadic true
  deflua seq(args), state do
    dispatch("seq", args, state)
  end

  @variadic true
  deflua env(args), state do
    dispatch("env", args, state)
  end

  @variadic true
  deflua rm(args), state do
    dispatch("rm", args, state)
  end

  @variadic true
  deflua cp(args), state do
    dispatch("cp", args, state)
  end

  @doc false
  def print(args, %Lua{} = lua) when is_list(args) do
    context = fetch_context!(lua)

    output =
      args
      |> Enum.map(&lua_to_string/1)
      |> Enum.join("\t")

    context.emit.({:output, output <> "\n"})
    {[], lua}
  end

  @doc false
  def dispatch(command, args, %Lua{} = lua) when command in @commands and is_list(args) do
    context = fetch_context!(lua)
    state = build_state!(context)
    line = build_line(command, Enum.map(args, &lua_to_string/1))

    case CommandRunner.execute(state, line, context.emit) do
      {:ok, {:state_update, changes}} ->
        updated_context = apply_state_update(context, changes)
        {[], Lua.put_private(lua, @context_key, updated_context)}

      {:ok, _} ->
        {[], lua}

      {:error, %Error{} = error} ->
        context.emit.({:output_stderr, error.message <> "\n"})
        raise Lua.RuntimeException, "jido.#{command}: #{error.message}"
    end
  end

  defp fetch_context!(%Lua{} = lua) do
    case Lua.get_private(lua, @context_key) do
      {:ok, context} when is_map(context) ->
        context

      _ ->
        raise Lua.RuntimeException, "missing Jido eval context"
    end
  end

  defp build_state!(context) do
    State.new!(%{
      id: Map.get(context, :session_id, "lua-interop"),
      workspace_id: Map.fetch!(context, :workspace_id),
      cwd: Map.get(context, :cwd, "/"),
      env: Map.get(context, :env, %{}),
      meta: %{execution_context: Map.get(context, :execution_context, %{})}
    })
  end

  defp apply_state_update(context, changes) when is_map(changes) do
    Enum.reduce(changes, context, fn
      {:cwd, cwd}, acc when is_binary(cwd) -> Map.put(acc, :cwd, cwd)
      {:env, env}, acc when is_map(env) -> Map.put(acc, :env, env)
      _, acc -> acc
    end)
  end

  defp build_line(command, []), do: command

  defp build_line(command, args) do
    Enum.join([command | Enum.map(args, &escape_arg/1)], " ")
  end

  defp escape_arg(arg) when is_binary(arg) do
    escaped =
      arg
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp lua_to_string(nil), do: ""
  defp lua_to_string(value) when is_binary(value), do: value
  defp lua_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp lua_to_string(value) when is_float(value), do: Float.to_string(value)
  defp lua_to_string(true), do: "true"
  defp lua_to_string(false), do: "false"
  defp lua_to_string(value), do: inspect(value)
end
