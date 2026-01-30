defmodule SampleApp.SwitchBot do
  @moduledoc false
  import Bitwise

  # Payload format from the driver:
  # <<addr:6, rssi:s8, svc_len:u8, svc:svc_len, mfg_len:u8, mfg:mfg_len>>
  def parse_frame!(<<addr::binary-6, rssi::signed-8, svc_len::unsigned-8, rest::binary>>) do
    <<svc::binary-size(svc_len), mfg_len::unsigned-8, mfg::binary-size(mfg_len)>> = rest

    %{
      addr: addr,
      rssi: rssi,
      svc: svc,
      mfg: mfg,
      device_id: device_id(mfg)
    }
  end

  def decode(%{svc: <<model, _::binary>>} = frame) do
    case model do
      0x54 -> decode_meter(frame)
      0x77 -> decode_outdoor_meter(frame)
      0x64 -> decode_contact(frame)
      0x73 -> decode_motion(frame)
      _ -> {:unknown, frame}
    end
  end

  defp device_id(mfg) when byte_size(mfg) >= 8 do
    <<_::binary-6, hi::unsigned-8, lo::unsigned-8, _::binary>> = mfg
    hi <<< 8 ||| lo
  end

  defp device_id(_), do: nil

  # ---- Meter (0x54) / Outdoor Meter (0x77)
  # Using your Arduino decode:
  # battery = svc[2] & 0x7F
  # isAboveFreezing = mfg[11] & 0x80
  # temp = (mfg[10] & 0x0F)/10 + (mfg[11] & 0x7F); negate if not above freezing
  # humidity = mfg[12] & 0x7F
  defp decode_meter(%{svc: svc, mfg: mfg} = frame) do
    with true <- byte_size(svc) >= 3,
         true <- byte_size(mfg) >= 13 do
      <<_model, _b1, b2, _::binary>> = svc
      battery = b2 &&& 0x7F

      <<_::binary-10, t10, t11, t12, _::binary>> = mfg
      above_freezing = (t11 &&& 0x80) != 0

      temp =
        (t10 &&& 0x0F) / 10.0 + (t11 &&& 0x7F)

      temperature = if above_freezing, do: temp, else: -temp
      humidity = t12 &&& 0x7F

      {:meter,
       Map.merge(frame, %{
         battery: battery,
         temperature_c: temperature,
         humidity_percent: humidity
       })}
    else
      _ -> {:meter_raw, frame}
    end
  end

  defp decode_outdoor_meter(frame), do: decode_meter(frame)

  # ---- Contact (0x64)
  defp decode_contact(%{svc: svc} = frame) do
    with true <- byte_size(svc) >= 9 do
      <<_model, b1, b2, b3, t4, t5, t6, t7, b8, _::binary>> = svc

      battery = b2 &&& 0x7F
      pir = if (b1 &&& 0x40) != 0, do: 1, else: 0
      door = if (b3 &&& 0x02) != 0, do: 1, else: 0
      door_timeout = if (b3 &&& 0x04) != 0, do: 1, else: 0
      illuminance_flag = if (b3 &&& 0x01) != 0, do: 1, else: 0
      button_count = b8 &&& 0x0F

      time01 = t4 <<< 8 ||| t5
      time02 = t6 <<< 8 ||| t7

      {:contact,
       Map.merge(frame, %{
         battery: battery,
         pir: pir,
         door: door,
         door_timeout: door_timeout,
         illuminance_flag: illuminance_flag,
         button_count: button_count,
         time01: time01,
         time02: time02
       })}
    else
      _ -> {:contact_raw, frame}
    end
  end

  # ---- Motion (0x73)
  defp decode_motion(%{svc: svc} = frame) do
    with true <- byte_size(svc) >= 6 do
      <<_model, b1, b2, b3, b4, b5, _::binary>> = svc

      battery = b2 &&& 0x7F
      pir = if (b1 &&& 0x40) != 0, do: 1, else: 0
      time01 = b3 <<< 8 ||| b4
      illuminance = (b5 &&& 0x03) - 1

      {:motion,
       Map.merge(frame, %{
         battery: battery,
         pir: pir,
         time01: time01,
         illuminance: illuminance
       })}
    else
      _ -> {:motion_raw, frame}
    end
  end
end
