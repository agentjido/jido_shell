defmodule Jido.Shell.Command.Registry do
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
      "echo" => Jido.Shell.Command.Echo,
      "pwd" => Jido.Shell.Command.Pwd,
      "ls" => Jido.Shell.Command.Ls,
      "cat" => Jido.Shell.Command.Cat,
      "cd" => Jido.Shell.Command.Cd,
      "mkdir" => Jido.Shell.Command.Mkdir,
      "write" => Jido.Shell.Command.Write,
      "sleep" => Jido.Shell.Command.Sleep,
      "seq" => Jido.Shell.Command.Seq,
      "help" => Jido.Shell.Command.Help,
      "env" => Jido.Shell.Command.Env,
      "rm" => Jido.Shell.Command.Rm,
      "cp" => Jido.Shell.Command.Cp
    }
  end
end
