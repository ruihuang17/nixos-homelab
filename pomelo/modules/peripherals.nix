{ pkgs, ... }:
{
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  hardware.printers = {
    ensureDefaultPrinter = "WF-2930_Series";
    ensurePrinters = [
      {
        name = "WF-2930_Series";
        description = "EPSON WF-2930 Series (driverless)";
        deviceUri = "ipps://EPSON0E42B8.local:631/ipp/print";
        model = "everywhere";
      }
    ];
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # YubiKey: smartcard daemon for Yubico Authenticator.
  services.pcscd.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
  };
}
