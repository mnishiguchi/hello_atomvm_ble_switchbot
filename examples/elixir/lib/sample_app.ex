defmodule SampleApp do
  @moduledoc """
  Minimal SwitchBot BLE reader demo for AtomVM.

  This module:
  - opens the native port driver
  - starts BLE scanning on the native side
  - polls for the latest merged SwitchBot frame
  - decodes the frame in Elixir (via SampleApp.SwitchBot)

  Expected dependencies in this project:
  - SampleApp.Port
  - SampleApp.SwitchBot
  """

  @poll_interval_ms 1_000

  # If you want to lock onto a specific SwitchBot device ID (the 16-bit id you print as %04x),
  # set this to an integer like 0x8006. Otherwise leave it as nil to read the latest frame seen.
  @target_device_id nil
  # @target_device_id 0x8006

  def start() do
    port = SampleApp.Port.open()
    IO.puts("Port opened: #{inspect(port)}")

    case SampleApp.Port.ble_start(port) do
      {:ok, _} ->
        IO.puts("BLE scan started")

      {:error, reason} ->
        IO.puts("BLE scan start failed: #{inspect(reason)}")
    end

    loop(port)
  end

  defp loop(port) do
    case fetch_frame(port) do
      {:ok, payload} ->
        frame = SampleApp.SwitchBot.parse_frame!(payload)

        decoded =
          case SampleApp.SwitchBot.decode(frame) do
            {:unknown, _} = u -> u
            other -> other
          end

        print_decoded(decoded)

      {:error, {:driver_error, 0x41}} ->
        # "no data yet" (per the suggested native error code)
        IO.puts("No SwitchBot frame yet")

      {:error, reason} ->
        IO.puts("Read failed: #{inspect(reason)}")
    end

    Process.sleep(@poll_interval_ms)
    loop(port)
  end

  defp fetch_frame(port) do
    case @target_device_id do
      nil -> SampleApp.Port.latest(port)
      id -> SampleApp.Port.latest_for_id(port, id)
    end
  end

  defp print_decoded({:meter, data}), do: print_common("METER", data)
  defp print_decoded({:motion, data}), do: print_common("MOTION", data)
  defp print_decoded({:contact, data}), do: print_common("CONTACT", data)
  defp print_decoded({:meter_raw, data}), do: print_common("METER(raw)", data)
  defp print_decoded({:motion_raw, data}), do: print_common("MOTION(raw)", data)
  defp print_decoded({:contact_raw, data}), do: print_common("CONTACT(raw)", data)
  defp print_decoded({:unknown, data}), do: print_common("UNKNOWN", data)

  defp print_common(kind, data) when is_map(data) do
    device_id =
      case Map.get(data, :device_id) do
        nil -> "----"
        id -> hex4(id)
      end

    addr = mac(data.addr)
    rssi = data.rssi

    battery =
      case Map.fetch(data, :battery) do
        {:ok, b} -> "#{b}%"
        :error -> "-"
      end

    temp =
      case Map.fetch(data, :temperature_c) do
        {:ok, t} -> "#{format_1dp(t)}C"
        :error -> "-"
      end

    hum =
      case Map.fetch(data, :humidity_percent) do
        {:ok, h} -> "#{h}%"
        :error -> "-"
      end

    pir =
      case Map.fetch(data, :pir) do
        {:ok, p} -> "#{p}"
        :error -> "-"
      end

    IO.puts(
      "[#{kind}] id=#{device_id} addr=#{addr} rssi=#{rssi} batt=#{battery} temp=#{temp} hum=#{hum} pir=#{pir}"
    )
  end

  # Avoid Enum/String to keep the AVM image minimal.
  defp mac(<<a, b, c, d, e, f>>) do
    hex2(f) <>
      ":" <> hex2(e) <> ":" <> hex2(d) <> ":" <> hex2(c) <> ":" <> hex2(b) <> ":" <> hex2(a)
  end

  # Zero-padded hex formatting without Elixir.String
  defp hex2(n) when is_integer(n) and n in 0..255 do
    :io_lib.format(~c"~2.16.0b", [n]) |> :erlang.iolist_to_binary()
  end

  defp hex4(n) when is_integer(n) and n in 0..0xFFFF do
    :io_lib.format(~c"~4.16.0b", [n]) |> :erlang.iolist_to_binary()
  end

  defp format_1dp(f) when is_float(f) do
    :io_lib.format("~.1f", [f]) |> IO.iodata_to_binary()
  end

  defp format_1dp(i) when is_integer(i) do
    format_1dp(i * 1.0)
  end
end
