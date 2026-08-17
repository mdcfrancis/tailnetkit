package pairing

import (
	"fmt"

	qrcode "github.com/skip2/go-qrcode"
)

// QRPNG renders a payload as a PNG QR code, size pixels square.
//
// The Swift side returns a CGImage from PairingQR; a Go host is almost always
// putting this in a web page or a file, so bytes are the useful currency.
//
// Medium error correction matches the Swift renderer. Higher levels survive a
// dirtier scan but pack the modules tighter, which hurts more than it helps for
// a code displayed on a screen and scanned from a foot away.
func QRPNG(p Payload, size int) ([]byte, error) {
	encoded, err := p.Encode()
	if err != nil {
		return nil, err
	}
	if size <= 0 {
		size = 512
	}
	png, err := qrcode.Encode(encoded, qrcode.Medium, size)
	if err != nil {
		return nil, fmt.Errorf("render pairing QR: %w", err)
	}
	return png, nil
}
