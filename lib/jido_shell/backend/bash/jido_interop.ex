if Code.ensure_loaded?(Bash.Interop) do
  defmodule Jido.Shell.Backend.Bash.JidoInterop do
    @moduledoc """
    `Bash.Interop` bridge that exposes registered Jido shell commands to scripts
    running inside a `Bash.Session`.

    For each entry in `Jido.Shell.Command.Registry.commands/0` (minus `bash` and
    `help`), this module defines a `defbash` handler named after the command. When
    bash calls `jido.echo hello`, the handler reconstructs a transient
    `Jido.Shell.ShellSession.State` from the current bash session state plus the
    captured workspace id, invokes `Jido.Shell.CommandRunner.execute/3`, and
    funnels the buffered output back through `Bash.puts/2`.

    The bash session's working directory and environment are kept in sync with
    Jido state transitions: a `cd` command emits `{:state_update, %{cwd: …}}`,
    and the bridge forwards that via `Bash.update_state/1` so subsequent bash
    builtins (and the outer backend) see the new cwd.

    Workspace id is taken from the bash session state under the
    `:jido_workspace_id` variable, which `Jido.Shell.Backend.Bash` sets during
    initialisation.

    ## Security — interop trust boundary

    `defbash` handlers execute as **unrestricted Elixir code** in the same BEAM
    process as the `Bash.Session` GenServer. The `:bash` library does not sandbox
    interop function bodies — a handler may call `File.*`, `System.cmd`,
    `System.get_env`, `spawn`, or any other BEAM API.

    This module is safe because every handler delegates to
    `Jido.Shell.CommandRunner.execute/3`, which routes through the VFS and the
    command registry. If you add a new interop module or modify a handler, ensure
    it does **not** perform direct host I/O or spawn OS processes — doing so would
    bypass the filesystem virtualisation and command policy that the rest of the
    backend enforces.
    """

    use Bash.Interop, namespace: "jido"

    alias Jido.Shell.CommandRunner
    alias Jido.Shell.ShellSession.State

    defbash(echo(args, session_state), do: __MODULE__.dispatch("echo", args, session_state))
    defbash(pwd(args, session_state), do: __MODULE__.dispatch("pwd", args, session_state))
    defbash(ls(args, session_state), do: __MODULE__.dispatch("ls", args, session_state))
    defbash(cat(args, session_state), do: __MODULE__.dispatch("cat", args, session_state))
    defbash(cd(args, session_state), do: __MODULE__.dispatch("cd", args, session_state))
    defbash(mkdir(args, session_state), do: __MODULE__.dispatch("mkdir", args, session_state))
    defbash(write(args, session_state), do: __MODULE__.dispatch("write", args, session_state))
    defbash(sleep(args, session_state), do: __MODULE__.dispatch("sleep", args, session_state))
    defbash(seq(args, session_state), do: __MODULE__.dispatch("seq", args, session_state))
    defbash(env(args, session_state), do: __MODULE__.dispatch("env", args, session_state))
    defbash(rm(args, session_state), do: __MODULE__.dispatch("rm", args, session_state))
    defbash(cp(args, session_state), do: __MODULE__.dispatch("cp", args, session_state))

    @doc false
    @spec dispatch(String.t(), [String.t()], map()) ::
            :ok | {:ok, binary()} | {:error, binary()}
    def dispatch(command, args, session_state) do
      with {:ok, state} <- build_state(session_state),
           line <- build_line(command, args),
           {stdout, stderr, result} <- run_command(state, line) do
        finalize(result, stdout, stderr)
      else
        {:error, :missing_workspace} ->
          {:error, "jido.#{command}: workspace not configured\n"}

        {:error, reason} ->
          {:error, "jido.#{command}: invalid session state: #{inspect(reason)}\n"}
      end
    end

    defp build_state(%{variables: variables} = session_state) do
      case Map.get(variables, "JIDO_WORKSPACE_ID") do
        nil ->
          {:error, :missing_workspace}

        var ->
          workspace_id = variable_value(var)
          cwd = Map.get(session_state, :working_dir, "/")
          env = variables_to_env(variables)

          State.new(%{
            id: "bash-interop",
            workspace_id: workspace_id,
            cwd: cwd,
            env: env
          })
      end
    end

    defp build_state(_), do: {:error, :missing_workspace}

    defp variable_value(%{value: value}) when is_binary(value), do: value
    defp variable_value(value) when is_binary(value), do: value
    defp variable_value(_), do: ""

    defp variables_to_env(variables) when is_map(variables) do
      variables
      |> Enum.flat_map(fn
        {"JIDO_WORKSPACE_ID", _} -> []
        {key, %{value: value}} when is_binary(value) -> [{key, value}]
        {key, value} when is_binary(value) -> [{key, value}]
        _ -> []
      end)
      |> Map.new()
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

    defp escape_arg(other), do: other |> to_string() |> escape_arg()

    defp run_command(state, line) do
      parent = self()
      ref = make_ref()

      emit = fn
        {:output, chunk} ->
          send(parent, {ref, :stdout, IO.iodata_to_binary(chunk)})
          :ok

        {:output_stderr, chunk} ->
          send(parent, {ref, :stderr, IO.iodata_to_binary(chunk)})
          :ok

        _ ->
          :ok
      end

      result = CommandRunner.execute(state, line, emit)
      {stdout, stderr} = drain(ref, [], [])
      {stdout, stderr, result}
    end

    defp drain(ref, stdout, stderr) do
      receive do
        {^ref, :stdout, chunk} -> drain(ref, [chunk | stdout], stderr)
        {^ref, :stderr, chunk} -> drain(ref, stdout, [chunk | stderr])
      after
        0 -> {stdout |> Enum.reverse() |> IO.iodata_to_binary(), stderr |> Enum.reverse() |> IO.iodata_to_binary()}
      end
    end

    defp finalize({:ok, {:state_update, changes}}, stdout, _stderr) do
      apply_state_update(changes)
      emit_ok(stdout)
    end

    defp finalize({:ok, _result}, stdout, _stderr) do
      emit_ok(stdout)
    end

    defp finalize({:error, %Jido.Shell.Error{} = error}, _stdout, stderr) do
      message =
        case stderr do
          "" -> error.message <> "\n"
          s -> s
        end

      {:error, message}
    end

    defp finalize({:error, other}, _stdout, stderr) when is_binary(stderr) and stderr != "" do
      _ = other
      {:error, stderr}
    end

    defp finalize({:error, other}, _stdout, _stderr) do
      {:error, inspect(other) <> "\n"}
    end

    defp emit_ok(""), do: :ok
    defp emit_ok(stdout) when is_binary(stdout), do: {:ok, stdout}

    defp apply_state_update(%{cwd: cwd} = changes) when is_binary(cwd) do
      updates = %{working_dir: cwd}
      updates = maybe_add_env(updates, changes)
      Bash.update_state(updates)
    end

    defp apply_state_update(%{env: _} = changes) do
      Bash.update_state(maybe_add_env(%{}, changes))
    end

    defp apply_state_update(_), do: :ok

    defp maybe_add_env(updates, %{env: env}) when is_map(env) do
      variables =
        Map.new(env, fn {k, v} ->
          {to_string(k), Bash.Variable.new(to_string(v))}
        end)

      Map.put(updates, :variables, variables)
    end

    defp maybe_add_env(updates, _), do: updates
  end
else
  defmodule Jido.Shell.Backend.Bash.JidoInterop do
    @moduledoc """
    Placeholder for the optional `:bash` interop bridge.

    Git dependencies compile the full source tree, but the `:bash` dependency is
    intentionally optional so Hex packages can exclude the bash backend. This
    fallback lets the package compile when `:bash` is not present; the bash
    backend still reports `:bash_dep_unavailable` from init.
    """

    @doc false
    @spec dispatch(String.t(), [String.t()], map()) :: {:error, binary()}
    def dispatch(command, _args, _session_state) do
      {:error, "jido.#{command}: bash dependency unavailable\n"}
    end
  end
end
