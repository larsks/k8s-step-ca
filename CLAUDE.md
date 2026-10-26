This project is for testing out the step-ca certificate authority. The environment we are modeling will be issuing certificates for internal servers, BMCs, and network devices. Target devices include Dell iDRAC 8 BMCs, which require RSA certificates and have no support for ACME or SCEP. We will be issuing certificates for a number of devices that are accessed by IP rather than by name.

There may be some Linux servers that are able to take advantage of the ACME provisioner.
