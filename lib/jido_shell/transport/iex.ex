defmodule Jido.Shell.Transport.IEx do
  @moduledoc """
  Interactive IEx transport for Jido.Shell sessions.

  Provides a REPL interface within IEx, reading input with `IO.gets`
  and printing output with ANSI formatting.

  ## Usage

      iex> Jido.Shell.Transport.IEx.start("my_workspace")
      # Enters interactive shell mode
      /home> ls
      file1.txt
      file2.txt
      /home> exit
      :ok

  Use "exit" or press Ctrl+C to exit the shell.
  """

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer

  @prompt_color IO.ANSI.cyan()
  @error_color IO.ANSI.red()
  @reset IO.ANSI.reset()

  @doc """
  Starts an interactive session for the given workspace.

  This function blocks and runs the REPL until the user exits.
  """
  @spec start(String.t(), keyword()) :: :ok | {:error, Jido.Shell.Error.t() | term()}
  def start(workspace_id, opts \\ []) when is_binary(workspace_id) do
    session_result =
      case Keyword.get(opts, :session_id) do
        nil -> ShellSession.start_with_vfs(workspace_id, opts)
        session_id -> {:ok, session_id}
      end

    with {:ok, session_id} <- session_result,
         {:ok, :subscribed} <- ShellSessionServer.subscribe(session_id, self()),
         {:ok, initial_state} <- ShellSessionServer.get_state(session_id) do
      IO.puts("Jido.Shell v#{Jido.Shell.version()}")
      IO.puts("Type \"exit\" to quit, \"help\" for commands.\n")

      loop(session_id, initial_state.cwd, opts)
    end
  end

  @doc """
  Attaches to an existing session.
  """
  @spec attach(String.t(), keyword()) :: :ok | {:error, Jido.Shell.Error.t() | :not_found}
  def attach(session_id, opts \\ []) do
    case ShellSession.lookup(session_id) do
      {:ok, _pid} ->
        with {:ok, :subscribed} <- ShellSessionServer.subscribe(session_id, self()),
             {:ok, state} <- ShellSessionServer.get_state(session_id) do
          IO.puts("Attached to session #{session_id}")
          loop(session_id, state.cwd, opts)
        end

      {:error, :not_found} = error ->
        error
    end
  end

  # === Private ===

  defp loop(session_id, cwd, opts) do
    prompt = format_prompt(cwd)
    timeout = wait_timeout(opts)

    case read_line(prompt, opts) do
      :eof ->
        IO.puts("\nGoodbye!")
        :ok

      {:error, _reason} ->
        IO.puts("\nInput error, exiting.")
        :ok

      line when is_binary(line) ->
        line = String.trim(line)

        case handle_input(session_id, line, cwd, timeout) do
          {:continue, new_cwd} ->
            loop(session_id, new_cwd, opts)

          :exit ->
            IO.puts("Goodbye!")
            :ok
        end
    end
  end

  defp handle_input(_session_id, "", cwd, _timeout), do: {:continue, cwd}
  defp handle_input(_session_id, "exit", _cwd, _timeout), do: :exit
  defp handle_input(_session_id, "quit", _cwd, _timeout), do: :exit

  defp handle_input(session_id, line, cwd, timeout_ms) do
    case ShellSessionServer.run_command(session_id, line) do
      {:ok, :accepted} ->
        new_cwd = wait_for_completion(session_id, cwd, timeout_ms)
        {:continue, new_cwd}

      {:error, error} ->
        print_error(error)
        {:continue, cwd}
    end
  end

  defp wait_for_completion(session_id, cwd, timeout_ms) do
    receive do
      {:jido_shell_session, ^session_id, {:command_started, _line}} ->
        wait_for_completion(session_id, cwd, timeout_ms)

      {:jido_shell_session, ^session_id, {:output, chunk}} ->
        IO.write(chunk)
        wait_for_completion(session_id, cwd, timeout_ms)

      {:jido_shell_session, ^session_id, {:error, error}} ->
        print_error(error)
        cwd

      {:jido_shell_session, ^session_id, {:cwd_changed, new_cwd}} ->
        wait_for_completion(session_id, new_cwd, timeout_ms)

      {:jido_shell_session, ^session_id, :command_done} ->
        cwd

      {:jido_shell_session, ^session_id, :command_cancelled} ->
        IO.puts("\n#{@error_color}Cancelled#{@reset}")
        cwd

      {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
        IO.puts("#{@error_color}Command crashed: #{inspect(reason)}#{@reset}")
        cwd
    after
      timeout_ms ->
        IO.puts("#{@error_color}Timeout waiting for command#{@reset}")
        cwd
    end
  end

  defp read_line(prompt, opts) do
    case Keyword.get(opts, :line_reader) do
      reader when is_function(reader, 1) -> reader.(prompt)
      _ -> IO.gets(prompt)
    end
  end

  defp wait_timeout(opts) do
    case Keyword.get(opts, :wait_timeout_ms, 60_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> 60_000
    end
  end

  defp format_prompt(cwd) do
    "#{@prompt_color}#{cwd}#{@reset}> "
  end

  defp print_error(%Jido.Shell.Error{} = error) do
    IO.puts("#{@error_color}Error: #{error.message}#{@reset}")
  end

  defp print_error(error) do
    IO.puts("#{@error_color}Error: #{inspect(error)}#{@reset}")
  end
end
