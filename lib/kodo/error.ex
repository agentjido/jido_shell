defmodule Kodo.Error do
  @moduledoc """
  Structured error for Kodo operations.

  Provides consistent error handling across VFS, shell, commands, and sessions.
  The code field uses category tuples for easy pattern matching.

  ## Error Categories

  - `{:vfs, code}` - Virtual filesystem errors (not_found, permission_denied, etc.)
  - `{:shell, code}` - Shell-level errors (unknown_command, syntax_error, etc.)
  - `{:validation, code}` - Argument validation errors
  - `{:session, code}` - Session lifecycle errors
  - `{:command, code}` - Command execution errors

  ## Examples

      # Creating errors
      error = Kodo.Error.vfs(:not_found, "/missing/file")
      error = Kodo.Error.shell(:unknown_command, %{name: "foo"})

      # Pattern matching on category
      case error.code do
        {:vfs, :not_found} -> "File not found"
        {:shell, :unknown_command} -> "Unknown command"
        _ -> error.message
      end

  """

  defexception [:code, :message, context: %{}]

  @type error_code :: atom() | {atom(), atom()}
  @type t :: %__MODULE__{
          code: error_code(),
          message: String.t(),
          context: map()
        }

  @doc """
  Creates a VFS-related error.

  ## Parameters

  - `code` - Error code atom (e.g., :not_found, :permission_denied, :is_directory)
  - `path` - The path that caused the error
  - `ctx` - Additional context map (optional)

  ## Examples

      iex> error = Kodo.Error.vfs(:not_found, "/missing/file")
      iex> error.code
      {:vfs, :not_found}
      iex> error.context.path
      "/missing/file"

  """
  @spec vfs(atom(), String.t(), map()) :: t()
  def vfs(code, path, ctx \\ %{}) do
    %__MODULE__{
      code: {:vfs, code},
      message: "#{code}: #{path}",
      context: Map.put(ctx, :path, path)
    }
  end

  @doc """
  Creates a shell-level error.

  ## Parameters

  - `code` - Error code atom (e.g., :unknown_command, :syntax_error, :busy)
  - `ctx` - Additional context map (optional)

  ## Examples

      iex> error = Kodo.Error.shell(:unknown_command, %{name: "foo"})
      iex> error.code
      {:shell, :unknown_command}
      iex> error.context.name
      "foo"

  """
  @spec shell(atom(), map()) :: t()
  def shell(code, ctx \\ %{}) do
    %__MODULE__{
      code: {:shell, code},
      message: to_string(code),
      context: ctx
    }
  end

  @doc """
  Creates a validation error for command arguments.

  ## Parameters

  - `command` - The command name that had validation errors
  - `zoi_errors` - The Zoi validation errors
  - `ctx` - Additional context map (optional)

  ## Examples

      iex> error = Kodo.Error.validation("cp", [%{path: [:source], message: "is required"}])
      iex> error.code
      {:validation, :invalid_args}
      iex> error.context.command
      "cp"

  """
  @spec validation(String.t(), list(), map()) :: t()
  def validation(command, zoi_errors, ctx \\ %{}) do
    %__MODULE__{
      code: {:validation, :invalid_args},
      message: "invalid arguments for #{command}",
      context: ctx |> Map.put(:command, command) |> Map.put(:zoi_errors, zoi_errors)
    }
  end

  @doc """
  Creates a session-related error.

  ## Parameters

  - `code` - Error code atom (e.g., :not_found, :already_exists, :terminated)
  - `ctx` - Additional context map (optional)

  ## Examples

      iex> error = Kodo.Error.session(:not_found, %{session_id: "abc123"})
      iex> error.code
      {:session, :not_found}

  """
  @spec session(atom(), map()) :: t()
  def session(code, ctx \\ %{}) do
    %__MODULE__{
      code: {:session, code},
      message: to_string(code),
      context: ctx
    }
  end

  @doc """
  Creates a command execution error.

  ## Parameters

  - `code` - Error code atom (e.g., :timeout, :crashed, :llm_failed)
  - `ctx` - Additional context map (optional)

  ## Examples

      iex> error = Kodo.Error.command(:timeout, %{command: "llm", elapsed_ms: 30000})
      iex> error.code
      {:command, :timeout}

  """
  @spec command(atom(), map()) :: t()
  def command(code, ctx \\ %{}) do
    %__MODULE__{
      code: {:command, code},
      message: to_string(code),
      context: ctx
    }
  end

  @doc """
  Returns the error category from the code.

  ## Examples

      iex> error = Kodo.Error.vfs(:not_found, "/path")
      iex> Kodo.Error.category(error)
      :vfs

  """
  @spec category(t()) :: atom()
  def category(%__MODULE__{code: {category, _}}), do: category
  def category(%__MODULE__{code: code}) when is_atom(code), do: code

  @doc """
  Returns the specific error code without the category.

  ## Examples

      iex> error = Kodo.Error.vfs(:not_found, "/path")
      iex> Kodo.Error.reason(error)
      :not_found

  """
  @spec reason(t()) :: atom()
  def reason(%__MODULE__{code: {_, reason}}), do: reason
  def reason(%__MODULE__{code: code}) when is_atom(code), do: code
end
