package main

import "errors"

// errNeedMoreData signals that b does not yet contain a complete TLS
// ClientHello and the caller should read more bytes before retrying.
var errNeedMoreData = errors.New("boring-egress: incomplete ClientHello")

// errNotClientHello is returned when the leading bytes are not a TLS handshake
// ClientHello (e.g. plain HTTP, or a TLS alert). The connection cannot be
// hostname-filtered and is rejected by the caller.
var errNotClientHello = errors.New("boring-egress: not a TLS ClientHello")

// extractSNI parses the server_name (SNI) from a TLS ClientHello at the start
// of b. It returns the lowercased-by-caller hostname and the total length of
// the TLS record (5-byte header + body) so the caller knows it has buffered a
// whole record. It does NO decryption — SNI is plaintext in the ClientHello —
// so this is inspection, not interception, which is the whole point: we filter
// on the hostname the client asked for without holding its keys.
//
// Returns errNeedMoreData if b is truncated mid-record (read more, retry),
// errNotClientHello if the bytes aren't a handshake ClientHello, and an empty
// host with nil error only if the ClientHello legitimately carries no SNI.
func extractSNI(b []byte) (host string, recordLen int, err error) {
	// TLS record header: type(1) version(2) length(2).
	if len(b) < 5 {
		return "", 0, errNeedMoreData
	}
	if b[0] != 0x16 { // handshake
		return "", 0, errNotClientHello
	}
	recLen := int(b[3])<<8 | int(b[4])
	recordLen = 5 + recLen
	if len(b) < recordLen {
		return "", recordLen, errNeedMoreData
	}
	body := b[5:recordLen]

	// Handshake header: msg_type(1) length(3).
	if len(body) < 4 {
		return "", recordLen, errNeedMoreData
	}
	if body[0] != 0x01 { // ClientHello
		return "", recordLen, errNotClientHello
	}
	hsLen := int(body[1])<<16 | int(body[2])<<8 | int(body[3])
	p := body[4:]
	if len(p) < hsLen {
		return "", recordLen, errNeedMoreData
	}
	p = p[:hsLen]

	// legacy_version(2) + random(32).
	if len(p) < 34 {
		return "", recordLen, errNeedMoreData
	}
	p = p[34:]

	// session_id: len(1) + id.
	if len(p) < 1 {
		return "", recordLen, errNeedMoreData
	}
	sidLen := int(p[0])
	p = p[1:]
	if len(p) < sidLen {
		return "", recordLen, errNeedMoreData
	}
	p = p[sidLen:]

	// cipher_suites: len(2) + suites.
	if len(p) < 2 {
		return "", recordLen, errNeedMoreData
	}
	csLen := int(p[0])<<8 | int(p[1])
	p = p[2:]
	if len(p) < csLen {
		return "", recordLen, errNeedMoreData
	}
	p = p[csLen:]

	// compression_methods: len(1) + methods.
	if len(p) < 1 {
		return "", recordLen, errNeedMoreData
	}
	cmLen := int(p[0])
	p = p[1:]
	if len(p) < cmLen {
		return "", recordLen, errNeedMoreData
	}
	p = p[cmLen:]

	// extensions: len(2) + extensions. Absent extensions block = no SNI.
	if len(p) < 2 {
		return "", recordLen, nil
	}
	extLen := int(p[0])<<8 | int(p[1])
	p = p[2:]
	if len(p) < extLen {
		return "", recordLen, errNeedMoreData
	}
	ext := p[:extLen]

	for len(ext) >= 4 {
		extType := int(ext[0])<<8 | int(ext[1])
		thisLen := int(ext[2])<<8 | int(ext[3])
		ext = ext[4:]
		if len(ext) < thisLen {
			return "", recordLen, errNeedMoreData
		}
		data := ext[:thisLen]
		ext = ext[thisLen:]

		if extType != 0x0000 { // server_name
			continue
		}
		// server_name_list: list_len(2) then entries of
		// name_type(1) + name_len(2) + name.
		if len(data) < 2 {
			return "", recordLen, nil
		}
		listLen := int(data[0])<<8 | int(data[1])
		d := data[2:]
		if len(d) < listLen {
			return "", recordLen, errNeedMoreData
		}
		d = d[:listLen]
		for len(d) >= 3 {
			nameType := d[0]
			nameLen := int(d[1])<<8 | int(d[2])
			d = d[3:]
			if len(d) < nameLen {
				return "", recordLen, errNeedMoreData
			}
			if nameType == 0x00 { // host_name
				return string(d[:nameLen]), recordLen, nil
			}
			d = d[nameLen:]
		}
		return "", recordLen, nil
	}
	return "", recordLen, nil
}
