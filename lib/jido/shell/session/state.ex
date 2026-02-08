defmodule Jido.Shell.Session.State do
  @moduledoc """
  Session state struct with Zoi schema validation.

  This struct represents the internal state held by a SessionServer,
  including the current working directory, environment variables,
  command history, and transport subscriptions.

  ## Fields

  - `id` - Unique session identifier (string)
  - `workspace_id` - The workspace this session belongs to (atom)
  - `cwd` - Current working directory (defaults to "/")
  - `env` - Environment variables (map)
  - `history` - Command history (list of strings)
  - `meta` - Additional metadata (map)
  - `transports` - Set of subscribed transport PIDs
  - `current_command` - Currently running command info, or nil

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "sess-123", workspace_id: :my_workspace})
      iex> state.cwd
      "/"
      iex> state.history
      []

  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              workspace_id: Zoi.atom(),
              cwd: Zoi.string() |> Zoi.default("/"),
              env: Zoi.map() |> Zoi.default(%{}),
              history: Zoi.array(Zoi.string()) |> Zoi.default([]),
              meta: Zoi.map() |> Zoi.default(%{}),
              transports: Zoi.any() |> Zoi.default(MapSet.new()),
              current_command: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema for Session.State.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Creates a new Session.State struct from a map, validating with Zoi schema.

  ## Parameters

  - `attrs` - Map with at least `:id` and `:workspace_id` keys

  ## Returns

  - `{:ok, state}` on success
  - `{:error, errors}` on validation failure

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "sess-1", workspace_id: :test})
      iex> state.id
      "sess-1"

      iex> {:error, _} = Jido.Shell.Session.State.new(%{})

  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    Zoi.parse(@schema, attrs)
  end

  @doc """
  Creates a new Session.State struct from a map, raising on validation errors.

  ## Examples

      iex> state = Jido.Shell.Session.State.new!(%{id: "sess-1", workspace_id: :test})
      iex> state.workspace_id
      :test

  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, errors} -> raise ArgumentError, "Invalid state: #{inspect(errors)}"
    end
  end

  @doc """
  Adds a transport PID to the session's transport set.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.add_transport(state, self())
      iex> MapSet.member?(state.transports, self())
      true

  """
  @spec add_transport(t(), pid()) :: t()
  def add_transport(%__MODULE__{} = state, pid) when is_pid(pid) do
    %{state | transports: MapSet.put(state.transports, pid)}
  end

  @doc """
  Removes a transport PID from the session's transport set.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.add_transport(state, self())
      iex> state = Jido.Shell.Session.State.remove_transport(state, self())
      iex> MapSet.member?(state.transports, self())
      false

  """
  @spec remove_transport(t(), pid()) :: t()
  def remove_transport(%__MODULE__{} = state, pid) when is_pid(pid) do
    %{state | transports: MapSet.delete(state.transports, pid)}
  end

  @doc """
  Adds a command line to the session history.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.add_to_history(state, "ls -la")
      iex> hd(state.history)
      "ls -la"

  """
  @spec add_to_history(t(), String.t()) :: t()
  def add_to_history(%__MODULE__{} = state, line) when is_binary(line) do
    %{state | history: [line | state.history]}
  end

  @doc """
  Updates the current working directory.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.set_cwd(state, "/home/user")
      iex> state.cwd
      "/home/user"

  """
  @spec set_cwd(t(), String.t()) :: t()
  def set_cwd(%__MODULE__{} = state, cwd) when is_binary(cwd) do
    %{state | cwd: cwd}
  end

  @doc """
  Sets the currently running command.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.set_current_command(state, %{line: "ls", task: self()})
      iex> state.current_command.line
      "ls"

  """
  @spec set_current_command(t(), map() | nil) :: t()
  def set_current_command(%__MODULE__{} = state, command) do
    %{state | current_command: command}
  end

  @doc """
  Clears the currently running command.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> state = Jido.Shell.Session.State.set_current_command(state, %{line: "ls"})
      iex> state = Jido.Shell.Session.State.clear_current_command(state)
      iex> state.current_command
      nil

  """
  @spec clear_current_command(t()) :: t()
  def clear_current_command(%__MODULE__{} = state) do
    %{state | current_command: nil}
  end

  @doc """
  Checks if a command is currently running.

  ## Examples

      iex> {:ok, state} = Jido.Shell.Session.State.new(%{id: "s", workspace_id: :w})
      iex> Jido.Shell.Session.State.command_running?(state)
      false

  """
  @spec command_running?(t()) :: boolean()
  def command_running?(%__MODULE__{current_command: nil}), do: false
  def command_running?(%__MODULE__{current_command: _}), do: true
end
