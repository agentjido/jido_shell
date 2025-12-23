defmodule Kodo.Transport.IEx do
  @moduledoc """
  Interactive IEx transport for Kodo sessions.

  Provides a REPL interface within IEx, reading input with `IO.gets`
  and printing output with ANSI formatting.

  ## Usage

      iex> Kodo.Transport.IEx.start(:my_workspace)
      # Enters interactive shell mode
      /home> ls
      file1.txt
      file2.txt
      /home> exit
      :ok

  Use "exit" or press Ctrl+C to exit the shell.
  """

  alias Kodo.Session
  alias Kodo.SessionServer

  @prompt_color IO.ANSI.cyan()
  @error_color IO.ANSI.red()
  @reset IO.ANSI.reset()

  @doc """
  Starts an interactive session for the given workspace.

  This function blocks and runs the REPL until the user exits.
  """
  @spec start(atom(), keyword()) :: :ok
  def start(workspace_id, opts \\ []) when is_atom(workspace_id) do
    session_id =
      Keyword.get_lazy(opts, :session_id, fn ->
        case Session.start_with_vfs(workspace_id, opts) do
          {:ok, id} -> id
          {:error, reason} -> raise "Failed to start session: #{inspect(reason)}"
        end
      end)

    :ok = SessionServer.subscribe(session_id, self())

    {:ok, initial_state} = SessionServer.get_state(session_id)

    IO.puts("Kodo Shell v#{Kodo.version()}")
    IO.puts("Type \"exit\" to quit, \"help\" for commands.\n")

    loop(session_id, initial_state.cwd)
  end

  @doc """
  Attaches to an existing session.
  """
  @spec attach(String.t()) :: :ok | {:error, :not_found}
  def attach(session_id) do
    case Session.lookup(session_id) do
      {:ok, _pid} ->
        :ok = SessionServer.subscribe(session_id, self())
        {:ok, state} = SessionServer.get_state(session_id)

        IO.puts("Attached to session #{session_id}")
        loop(session_id, state.cwd)

      {:error, :not_found} = error ->
        error
    end
  end

  # === Private ===

  defp loop(session_id, cwd) do
    prompt = format_prompt(cwd)

    case IO.gets(prompt) do
      :eof ->
        IO.puts("\nGoodbye!")
        :ok

      {:error, _reason} ->
        IO.puts("\nInput error, exiting.")
        :ok

      line when is_binary(line) ->
        line = String.trim(line)

        case handle_input(session_id, line, cwd) do
          {:continue, new_cwd} ->
            loop(session_id, new_cwd)

          :exit ->
            IO.puts("Goodbye!")
            :ok
        end
    end
  end

  defp handle_input(_session_id, "", cwd), do: {:continue, cwd}
  defp handle_input(_session_id, "exit", _cwd), do: :exit
  defp handle_input(_session_id, "quit", _cwd), do: :exit

  defp handle_input(session_id, line, cwd) do
    :ok = SessionServer.run_command(session_id, line)
    new_cwd = wait_for_completion(session_id, cwd)
    {:continue, new_cwd}
  end

  defp wait_for_completion(session_id, cwd) do
    receive do
      {:kodo_session, ^session_id, {:command_started, _line}} ->
        wait_for_completion(session_id, cwd)

      {:kodo_session, ^session_id, {:output, chunk}} ->
        IO.write(chunk)
        wait_for_completion(session_id, cwd)

      {:kodo_session, ^session_id, {:error, error}} ->
        print_error(error)
        cwd

      {:kodo_session, ^session_id, {:cwd_changed, new_cwd}} ->
        wait_for_completion(session_id, new_cwd)

      {:kodo_session, ^session_id, :command_done} ->
        cwd

      {:kodo_session, ^session_id, :command_cancelled} ->
        IO.puts("\n#{@error_color}Cancelled#{@reset}")
        cwd

      {:kodo_session, ^session_id, {:command_crashed, reason}} ->
        IO.puts("#{@error_color}Command crashed: #{inspect(reason)}#{@reset}")
        cwd
    after
      60_000 ->
        IO.puts("#{@error_color}Timeout waiting for command#{@reset}")
        cwd
    end
  end

  defp format_prompt(cwd) do
    "#{@prompt_color}#{cwd}#{@reset}> "
  end

  defp print_error(%Kodo.Error{} = error) do
    IO.puts("#{@error_color}Error: #{error.message}#{@reset}")
  end

  defp print_error(error) do
    IO.puts("#{@error_color}Error: #{inspect(error)}#{@reset}")
  end
end
