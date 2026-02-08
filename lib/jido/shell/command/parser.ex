defmodule Jido.Shell.Command.Parser do
  @moduledoc """
  Simple command line parser.

  Tokenizes input into command name and arguments.
  Supports quoted strings for arguments with spaces.

  ## Examples

      iex> Jido.Shell.Command.Parser.parse("echo hello world")
      {:ok, "echo", ["hello", "world"]}

      iex> Jido.Shell.Command.Parser.parse("echo \\"hello world\\"")
      {:ok, "echo", ["hello world"]}
  """

  @doc """
  Parses a command line into command name and arguments.

  Returns `{:ok, command, args}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def parse(line) when is_binary(line) do
    line = String.trim(line)

    if line == "" do
      {:error, :empty_command}
    else
      case tokenize(line) do
        {:ok, [cmd | args]} -> {:ok, cmd, args}
        {:ok, []} -> {:error, :empty_command}
        {:error, _} = error -> error
      end
    end
  end

  defp tokenize(line) do
    tokenize(line, [], nil)
  end

  defp tokenize("", tokens, nil) do
    {:ok, tokens}
  end

  defp tokenize("", tokens, current) do
    {:ok, tokens ++ [current]}
  end

  defp tokenize(<<?">> <> rest, tokens, current) do
    case consume_quoted(rest, "") do
      {:ok, quoted, remaining} ->
        current = (current || "") <> quoted
        tokenize(remaining, tokens, current)

      {:error, _} = error ->
        error
    end
  end

  defp tokenize(<<?\s>> <> rest, tokens, nil) do
    tokenize(String.trim_leading(rest), tokens, nil)
  end

  defp tokenize(<<?\s>> <> rest, tokens, current) do
    tokenize(String.trim_leading(rest), tokens ++ [current], nil)
  end

  defp tokenize(<<c::utf8>> <> rest, tokens, current) do
    current = (current || "") <> <<c::utf8>>
    tokenize(rest, tokens, current)
  end

  defp consume_quoted("", _acc) do
    {:error, :unclosed_quote}
  end

  defp consume_quoted(<<?">> <> rest, acc) do
    {:ok, acc, rest}
  end

  defp consume_quoted(<<c::utf8>> <> rest, acc) do
    consume_quoted(rest, acc <> <<c::utf8>>)
  end
end
