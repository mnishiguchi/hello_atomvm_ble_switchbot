defmodule SampleApp do
  @moduledoc """
  Minimal example of calling a native AtomVM port driver on ESP32.

  The message flow is:

    Elixir process -> :port.call/2 -> native driver (C) -> reply -> Elixir

  This module demonstrates:

  - Opening a native port driver (`SampleApp.Port`)
  - Sending commands via `:port.call/2`
  - Receiving binary replies from the native driver
  - Periodic looping to send `ping` and `echo` requests

  The driver protocol uses two opcodes:

  - `0x01` Ping: expects `<<"PONG">>`
  - `0x02` Echo: returns the payload unchanged
  """

  @tick_interval_ms 10_000

  def start() do
    # Open the AtomVM port by name.
    # This name must match the registered driver ID in your native port config.
    port = SampleApp.Port.open()
    IO.puts("Port opened: #{inspect(port)}")

    loop(port)
  end

  defp loop(port) do
    # Perform actions using the port driver.
    do_ping(port)
    do_echo(port)

    # Wait before repeating the sequence.
    Process.sleep(@tick_interval_ms)
    loop(port)
  end

  # PING
  #
  # Request:  <<0x01>>
  # Reply:
  #   - success: <<0x00, "PONG">>
  #   - failure: <<0x01, code>>
  defp do_ping(port) do
    case SampleApp.Port.ping(port) do
      :ok ->
        IO.puts("Ping: :ok")

      {:error, reason} ->
        IO.puts("Ping failed: #{inspect(reason)}")
    end
  end

  # ECHO
  #
  # Request:  <<0x02, payload::binary>>
  # Reply:
  #   - success: <<0x00, payload::binary>>
  #   - failure: <<0x01, code>>
  defp do_echo(port) do
    payload = "hello from Elixir: #{:erlang.system_time(:second)}"
    IO.puts("Echo request: #{inspect(payload)}")

    case SampleApp.Port.echo(port, payload) do
      {:ok, echoed} ->
        IO.puts("Echo reply: #{inspect(echoed)}")

      {:error, reason} ->
        IO.puts("Echo failed: #{inspect(reason)}")
    end
  end
end
