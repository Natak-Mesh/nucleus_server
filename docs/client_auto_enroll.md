# Client Certificate Auto-Enrollment

## Certificate Auto-Enrollment — Generating Client Certificates Automatically

Enable certificate auto-enrollment via the web administrative dashboard:

1. Open the menu (≡) → **Configuration** → **Security and Authentication**.
2. Click **Edit Security** and check **Enable Certificate Enrollment**.
3. Select **TAK Server CA**.
   > **Note:** The TAK Server CA is the **intermediate cert**.
4. **Signing Keystore File** — enter the path relative to `/opt/tak`:
   ```
   certs/files/<intermediate-cert>-signing.jks
   ```
   (The `.jks` resides in `/opt/tak/certs/files/`, but this field starts after `/opt/tak`.)
5. **Signing Keystore Password** — default is `atakatak`.
6. **Validity Days** — enter the number of days the auto-enrolled certificates remain valid.
7. Click **Submit**, then restart the takserver service:
   ```
   sudo systemctl restart takserver
   ```

## Issuing a Certificate using Auto-Enrollment

1. Create the user via the web administrative dashboard and place them in the appropriate group.
2. Provide the end user with:
   - The **intermediate cert** (`.p12`)
   - Their username and password
3. On the client (WinTAK / ATAK):
   - Install the **intermediate cert** on the device.
   - Check **Enroll for Client Certificate** and **User Authentication**.
   > iTAK does not support this method of enrollment.
4. Verify the issued certificate in the web admin console under **Administrative** → **Client Certificates**.
   - From this view you can show Active, Expired, Revoked, or Replaced certificates and revoke as needed.
   > After revoking a certificate, restart the takserver service.
