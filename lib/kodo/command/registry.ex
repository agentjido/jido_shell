defmodule Kodo.Command.Registry do
  @moduledoc """
  Registry for looking up command modules by name.
  """

  @doc """
  Looks up a command module by name.

  Returns `{:ok, module}` or `{:error, :not_found}`.
  """
  @spec lookup(String.t()) :: {:ok, module()} | {:error, :not_found}
  def lookup(name) do
    case commands()[name] do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  @doc """
  Returns a list of all available command names.
  """
  @spec list() :: [String.t()]
  def list do
    Map.keys(commands())
  end

  @doc """
  Returns the full command registry map.
  """
  @spec commands() :: %{String.t() => module()}
  def commands do
    %{
      "echo" => Kodo.Command.Echo,
      "pwd" => Kodo.Command.Pwd,
      "ls" => Kodo.Command.Ls,
      "cat" => Kodo.Command.Cat,
      "cd" => Kodo.Command.Cd,
      "mkdir" => Kodo.Command.Mkdir,
      "write" => Kodo.Command.Write,
      "sleep" => Kodo.Command.Sleep,
      "seq" => Kodo.Command.Seq,
      "help" => Kodo.Command.Help,
      "env" => Kodo.Command.Env,
      "rm" => Kodo.Command.Rm,
      "cp" => Kodo.Command.Cp
    }
  end
end
