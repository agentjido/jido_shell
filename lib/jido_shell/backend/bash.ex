defmodule Jido.Shell.Backend.Bash do
  @moduledoc """
  Backend that executes real Bash scripts via the `:bash` library
  ([tv-labs/bash](https://github.com/tv-labs/bash)).

  Unlike `Jido.Shell.Backend.Local`, which parses commands with the Jido shell
  parser and routes each statement to a registered command module, this backend
  hands the entire command line to a persistent `Bash.Session` GenServer. That
  means loops, conditionals, variable assignments, arithmetic expansion, and
  pipes all work as in normal Bash — state (variables, functions, cwd)
  persists across calls within the same jido session.

  Registered Jido commands (`echo`, `ls`, `cat`, …) are bridged into bash via
  `Jido.Shell.Backend.Bash.JidoInterop`, with bash function shims installed at
  init time so scripts can call them by their familiar names. Filesystem I/O
  routes through `Jido.Shell.Backend.Bash.VfsAdapter`, which delegates to
  `Jido.Shell.VFS`. The backend pins `command_policy: :no_external`, so bash
  scripts cannot spawn any host process — every effective command is either a
  bash builtin or a Jido interop call.

  ## Known limitations

    * External binaries (`grep`, `sed`, `awk`, `find`, `curl`, …) are blocked by
      the command policy — use the bridged Jido commands instead.
    * Glob support (`VfsAdapter.wildcard/3`) covers simple `*`/`?` patterns
      only.
    * `configure_network/2` is a no-op — network policy is fixed at
      `:no_external`.

  ## Usage

      {:ok, sid} =
        Jido.Shell.ShellSession.start("ws1", backend: {Jido.Shell.Backend.Bash, %{}})

      Jido.Shell.ShellSession.run_command(sid, "for i in 1 2 3; do echo $i; done")

  Requires the optional `:bash` dependency to be compiled into the release.
  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.Backend.Bash.JidoInterop
  alias Jido.Shell.Backend.Bash.VfsAdapter
  alias Jido.Shell.Error

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor

  @impl true
  def init(config) when is_map(config) do
    with :ok <- ensure_dep_available(),
         {:ok, session_pid} <- fetch_session_pid(config),
         workspace_id <- Map.get(config, :workspace_id, ""),
         {:ok, bash_session} <- start_bash_session(config, workspace_id),
         :ok <- install_prelude(bash_session) do
      {:ok,
       %{
         bash_session: bash_session,
         session_pid: session_pid,
         task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
         workspace_id: workspace_id,
         cwd: Map.get(config, :cwd, "/"),
         env: Map.get(config, :env, %{})
       }}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) and is_list(exec_opts) do
    line = command_line(command, args)
    session_pid = state.session_pid
    bash_session = state.bash_session
    previous_cwd = state.cwd

    emit = fn event -> send(session_pid, {:command_event, event}) end

    task_fun = fn ->
      result =
        case safe_parse(line) do
          {:error, parse_error} ->
            {:error, Error.command(:syntax_error, %{line: line, reason: inspect(parse_error)})}

          {:ok, ast} ->
            raw =
              case Bash.Session.execute(bash_session, ast, on_output: &stream_output(emit, &1)) do
                {:ok, execution} ->
                  case exit_code(execution) do
                    0 -> {:ok, nil}
                    code -> {:error, Error.command(:exit_code, %{exit_code: code, line: line})}
                  end

                {:error, execution} ->
                  {:error,
                   Error.command(:exit_code, %{
                     exit_code: exit_code(execution) || 1,
                     line: line
                   })}

                {:exit, _execution} ->
                  {:ok, nil}

                {:exec, _execution} ->
                  {:ok, nil}
              end

            maybe_augment_with_cwd(raw, bash_session, previous_cwd)
        end

      send(session_pid, {:command_finished, result})
      result
    end

    case Task.Supervisor.start_child(state.task_supervisor, task_fun) do
      {:ok, task_pid} -> {:ok, task_pid, state}
      {:error, reason} -> {:error, Error.command(:start_failed, %{reason: reason, line: line})}
    end
  end

  @impl true
  def cancel(state, command_ref) when is_pid(command_ref) do
    # Interrupt the in-flight Bash.Session.execute/3 call so it returns with
    # exit_code 130 (SIGINT convention). The session remains usable.
    if is_pid(state.bash_session) and Process.alive?(state.bash_session) do
      Bash.Session.cancel_execution(state.bash_session)
    end

    # Kill the Task wrapper (may already be finishing after cancel_execution).
    if Process.alive?(command_ref) do
      Process.exit(command_ref, :shutdown)
    end

    :ok
  end

  def cancel(_state, _command_ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(state) do
    case Map.get(state, :bash_session) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: safe_stop(pid)
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def cwd(state) do
    case safe_call(state.bash_session, &Bash.Session.get_cwd/1) do
      {:ok, cwd} -> {:ok, cwd, %{state | cwd: cwd}}
      _ -> {:ok, state.cwd, state}
    end
  end

  @impl true
  def cd(state, path) when is_binary(path) do
    _ = safe_call(state.bash_session, fn pid -> Bash.Session.chdir(pid, path) end)
    {:ok, %{state | cwd: path}}
  end

  @impl true
  def configure_network(state, _policy), do: {:ok, state}

  # === private ===

  defp ensure_dep_available do
    if Code.ensure_loaded?(Bash.Session) do
      :ok
    else
      {:error, Error.command(:start_failed, %{reason: :bash_dep_unavailable})}
    end
  end

  defp fetch_session_pid(config) do
    case Map.get(config, :session_pid) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.session(:invalid_state_transition, %{reason: :missing_session_pid})}
    end
  end

  # Sandbox-safe defaults that prevent the `:bash` library from seeding
  # session variables with values read from the host OS at init time
  # (`System.get_env("HOME")`, `System.get_env("PATH")`, etc.).
  @sandbox_env_defaults %{
    "HOME" => "/",
    "PATH" => "",
    "MACHTYPE" => "beam-unknown-elixir"
  }

  defp start_bash_session(config, workspace_id) do
    user_env = Map.get(config, :env, %{})
    cwd = Map.get(config, :cwd, "/")

    env =
      @sandbox_env_defaults
      |> Map.merge(user_env)
      |> Map.put("JIDO_WORKSPACE_ID", workspace_id)

    opts = [
      filesystem: {VfsAdapter, %{workspace_id: workspace_id}},
      working_dir: cwd,
      env: env,
      command_policy: [commands: :no_external],
      apis: [JidoInterop]
    ]

    case Bash.Session.new(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, Error.command(:start_failed, %{reason: reason})}
    end
  end

  # Bash aliases are only active for interactive shells, so we install function
  # shims instead. Each shim routes the familiar command name (echo, ls, …) to
  # the corresponding `jido.*` interop handler.
  defp install_prelude(bash_session) do
    prelude = build_prelude()

    case safe_parse(prelude) do
      {:ok, ast} ->
        case Bash.Session.execute(bash_session, ast, []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, Error.command(:start_failed, %{reason: {:prelude_failed, reason}})}
          _ -> :ok
        end

      {:error, parse_error} ->
        {:error, Error.command(:start_failed, %{reason: {:prelude_parse_failed, parse_error}})}
    end
  end

  # `bash` and `help` are internal shell builtins that don't map to Jido
  # commands and are handled natively by the bash library.
  defp build_prelude do
    skip = ~w(bash help)

    Jido.Shell.Command.Registry.commands()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&(&1 in skip))
    |> Enum.map(fn name -> "#{name}() { jido.#{name} \"$@\"; }" end)
    |> Enum.join("\n")
  end

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")

  defp safe_parse(line) do
    case Bash.parse(line) do
      {:ok, ast} -> {:ok, ast}
      {:error, err} -> {:error, err}
    end
  end

  defp stream_output(emit, {:stdout, data}), do: emit.({:output, data})
  defp stream_output(emit, {:stderr, data}), do: emit.({:output_stderr, data})
  defp stream_output(_emit, _), do: :ok

  defp exit_code(%{exit_code: code}) when is_integer(code), do: code

  defp exit_code(execution) do
    try do
      Bash.ExecutionResult.exit_code(execution)
    rescue
      _ -> nil
    end
  end

  # After each command, pull the session's current working directory and, if it
  # changed, wrap the result in `{:state_update, %{cwd: new_cwd}}` so
  # `ShellSessionServer` applies the update and broadcasts `:cwd_changed`.
  defp maybe_augment_with_cwd({:ok, nil}, bash_session, previous_cwd) do
    case current_cwd(bash_session) do
      {:ok, cwd} when cwd != previous_cwd -> {:ok, {:state_update, %{cwd: cwd}}}
      _ -> {:ok, nil}
    end
  end

  defp maybe_augment_with_cwd(other, _bash_session, _previous_cwd), do: other

  defp current_cwd(bash_session) do
    case safe_call(bash_session, &Bash.Session.get_cwd/1) do
      {:ok, cwd} when is_binary(cwd) -> {:ok, cwd}
      _ -> :error
    end
  end

  defp safe_call(pid, fun) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, fun.(pid)}
    else
      {:error, :dead}
    end
  rescue
    _ -> {:error, :call_failed}
  catch
    _, _ -> {:error, :call_failed}
  end

  defp safe_stop(pid) do
    Bash.Session.stop(pid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
