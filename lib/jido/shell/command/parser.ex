defmodule Jido.Shell.Command.Parser do
  @moduledoc """
  Shell command parser with quoting, escaping, and chaining support.

  ## Examples

      iex> Jido.Shell.Command.Parser.parse("echo hello world")
      {:ok, "echo", ["hello", "world"]}

      iex> Jido.Shell.Command.Parser.parse("echo \\"hello world\\"")
      {:ok, "echo", ["hello world"]}
  """

  @typedoc "Execution gate for a parsed command"
  @type operator :: :always | :and_if

  @typedoc "Parsed command entry"
  @type command_entry :: %{operator: operator(), command: String.t(), args: [String.t()]}

  @doc """
  Parses a command line into command name and arguments.

  Returns `{:ok, command, args}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def parse(line) when is_binary(line) do
    case parse_program(line) do
      {:ok, [%{command: command, args: args}]} ->
        {:ok, command, args}

      {:ok, [_ | _]} ->
        {:error, :chained_command}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Parses a command line into one or more chained commands.

  Supported chaining operators:
  - `;` - Always run next command
  - `&&` - Run next command only if previous command succeeds
  """
  @spec parse_program(String.t()) :: {:ok, [command_entry()]} | {:error, term()}
  def parse_program(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:error, :empty_command}
    else
      with {:ok, tokens} <- tokenize(trimmed),
           {:ok, commands} <- build_program(tokens) do
        {:ok, commands}
      end
    end
  end

  defp tokenize(line) do
    tokenize(line, %{tokens: [], current: [], quote: nil, escaped: false})
  end

  defp tokenize("", %{quote: quote}) when not is_nil(quote) do
    {:error, :unclosed_quote}
  end

  defp tokenize("", %{escaped: true}) do
    {:error, :dangling_escape}
  end

  defp tokenize("", state) do
    state = flush_current(state)
    {:ok, Enum.reverse(state.tokens)}
  end

  defp tokenize(<<char::utf8, rest::binary>>, %{escaped: true} = state) do
    state
    |> push_char(char)
    |> Map.put(:escaped, false)
    |> then(&tokenize(rest, &1))
  end

  defp tokenize(<<?\\, rest::binary>>, state) do
    tokenize(rest, %{state | escaped: true})
  end

  defp tokenize(<<quote::utf8, rest::binary>>, %{quote: nil} = state) when quote in [?', ?"] do
    tokenize(rest, %{state | quote: quote})
  end

  defp tokenize(<<quote::utf8, rest::binary>>, %{quote: quote} = state) when quote in [?', ?"] do
    state =
      if state.current == [] do
        %{state | quote: nil, current: ["" | state.current]}
      else
        %{state | quote: nil}
      end

    tokenize(rest, state)
  end

  defp tokenize(<<char::utf8, rest::binary>>, %{quote: nil} = state) when char in [?\s, ?\t] do
    state
    |> flush_current()
    |> then(&tokenize(rest, &1))
  end

  defp tokenize(<<?;, rest::binary>>, %{quote: nil} = state) do
    state
    |> flush_current()
    |> push_token(:semicolon)
    |> then(&tokenize(rest, &1))
  end

  defp tokenize(<<?&, ?&, rest::binary>>, %{quote: nil} = state) do
    state
    |> flush_current()
    |> push_token(:and_and)
    |> then(&tokenize(rest, &1))
  end

  defp tokenize(<<char::utf8, rest::binary>>, state) do
    state
    |> push_char(char)
    |> then(&tokenize(rest, &1))
  end

  defp build_program(tokens) do
    build_program(tokens, [], [], :always)
  end

  defp build_program([], [], [], _next_operator), do: {:error, :empty_command}
  defp build_program([], [], _commands, _next_operator), do: {:error, :trailing_operator}

  defp build_program([], current_words, commands, next_operator) do
    {:ok, Enum.reverse([to_command(current_words, next_operator) | commands])}
  end

  defp build_program([token | rest], current_words, commands, next_operator) do
    case token do
      {:word, word} ->
        build_program(rest, [word | current_words], commands, next_operator)

      :semicolon ->
        case current_words do
          [] ->
            {:error, :invalid_operator_position}

          _ ->
            command = to_command(current_words, next_operator)
            build_program(rest, [], [command | commands], :always)
        end

      :and_and ->
        case current_words do
          [] ->
            {:error, :invalid_operator_position}

          _ ->
            command = to_command(current_words, next_operator)
            build_program(rest, [], [command | commands], :and_if)
        end
    end
  end

  defp to_command(words_reversed, operator) do
    [command | args] = Enum.reverse(words_reversed)
    %{operator: operator, command: command, args: args}
  end

  defp push_char(state, char) do
    %{state | current: [<<char::utf8>> | state.current]}
  end

  defp push_token(state, token) do
    %{state | tokens: [token | state.tokens]}
  end

  defp flush_current(%{current: []} = state), do: state

  defp flush_current(state) do
    word =
      state.current
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    state
    |> Map.put(:current, [])
    |> push_token({:word, word})
  end
end
