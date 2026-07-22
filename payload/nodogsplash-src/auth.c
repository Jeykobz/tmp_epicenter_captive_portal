/********************************************************************\
 * This program is free software; you can redistribute it and/or    *
 * modify it under the terms of the GNU General Public License as   *
 * published by the Free Software Foundation; either version 2 of   *
 * the License, or (at your option) any later version.              *
 *                                                                  *
 * This program is distributed in the hope that it will be useful,  *
 * but WITHOUT ANY WARRANTY; without even the implied warranty of   *
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the    *
 * GNU General Public License for more details.                     *
 *                                                                  *
 * You should have received a copy of the GNU General Public License*
 * along with this program; if not, contact:                        *
 *                                                                  *
 * Free Software Foundation           Voice:  +1-617-542-5942       *
 * 59 Temple Place - Suite 330        Fax:    +1-617-542-2652       *
 * Boston, MA  02111-1307,  USA       gnu@gnu.org                   *
 *                                                                  *
\********************************************************************/

/** @file auth.c
    @brief Authentication handling thread
    @author Copyright (C) 2004 Alexandre Carmel-Veilleux <acv@miniguru.ca>
*/

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <syslog.h>
#include <time.h>

#include "safe.h"
#include "conf.h"
#include "debug.h"
#include "auth.h"
#include "fw_iptables.h"
#include "client_list.h"
#include "util.h"


extern pthread_mutex_t client_list_mutex;
extern pthread_mutex_t config_mutex;

/* Count number of authentications */
unsigned int authenticated_since_start = 0;


static void binauth_action(t_client *client, const char *reason)
{
	s_config *config;

	config = config_get_config();

	if (config->binauth) {
		execute("%s %s %s %llu %llu %llu %llu",
			config->binauth,
			reason ? reason : "unknown",
			client->mac,
			client->counters.incoming,
			client->counters.outgoing,
			client->session_start,
			client->session_end
		);
	}
}

static int auth_change_state(t_client *client, const unsigned int new_state, const char *reason)
{
	const unsigned int state = client->fw_connection_state;

	if (state == new_state) {
		return -1;
	} else if (state == FW_MARK_PREAUTHENTICATED) {
		if (new_state == FW_MARK_AUTHENTICATED) {
			iptables_fw_authenticate(client);
			binauth_action(client, reason);
		} else if (new_state == FW_MARK_BLOCKED) {
			return -1;
		} else if (new_state == FW_MARK_TRUSTED) {
			return -1;
		} else {
			return -1;
		}
	} else if (state == FW_MARK_AUTHENTICATED) {
		if (new_state == FW_MARK_PREAUTHENTICATED) {
			iptables_fw_deauthenticate(client);
			binauth_action(client, reason);
			client_reset(client);
		} else if (new_state == FW_MARK_BLOCKED) {
			iptables_fw_deauthenticate(client);
			binauth_action(client, reason);
			auth_client_block(client->mac);
			client_list_delete(client);
			return 0;
		} else if (new_state == FW_MARK_TRUSTED) {
			return -1;
		} else {
			return -1;
		}
	} else if (state == FW_MARK_BLOCKED) {
		if (new_state == FW_MARK_PREAUTHENTICATED) {
			return -1;
		} else if (new_state == FW_MARK_AUTHENTICATED) {
			return -1;
		} else if (new_state == FW_MARK_TRUSTED) {
			return -1;
		} else {
			return -1;
		}
	} else if (state == FW_MARK_TRUSTED) {
		if (new_state == FW_MARK_PREAUTHENTICATED) {
			return -1;
		} else if (new_state == FW_MARK_AUTHENTICATED) {
			return -1;
		} else if (new_state == FW_MARK_BLOCKED) {
			return -1;
		} else {
			return -1;
		}
	} else {
		return -1;
	}

	client->fw_connection_state = new_state;

	return 0;
}

/** See if they are still active,
 *  refresh their traffic counters,
 *  remove and deny them if timed out
 */
static void
fw_refresh_client_list(void)
{
	t_client *cp1, *cp2;
	s_config *config = config_get_config();
	const int preauth_idle_timeout_secs = 60 * config->preauth_idle_timeout;
	const int auth_idle_timeout_secs = 60 * config->auth_idle_timeout;
	const time_t now = time(NULL);

	/* Update all the counters */
	if (-1 == iptables_fw_counters_update()) {
		debug(LOG_ERR, "Could not get counters from firewall!");
		return;
	}

	LOCK_CLIENT_LIST();

	for (cp1 = cp2 = client_get_first_client(); NULL != cp1; cp1 = cp2) {
		cp2 = cp1->next;

		if (!(cp1 = client_list_find_by_id(cp1->id))) {
			debug(LOG_ERR, "Client was freed while being re-validated!");
			continue;
		}

		unsigned int conn_state = cp1->fw_connection_state;
		time_t last_updated = cp1->counters.last_updated;

		if (cp1->session_end > 0 && cp1->session_end <= now) {
			/* Session ended (only > 0 for FW_MARK_AUTHENTICATED by binauth) */
			debug(LOG_NOTICE, "Force out user: %s %s, connected: %ds, in: %llukB, out: %llukB",
				cp1->ip, cp1->mac, now - cp1->session_end,
				cp1->counters.incoming / 1000, cp1->counters.outgoing / 1000);

			if (config->session_timeout_block > 0) {
				auth_change_state(cp1, FW_MARK_BLOCKED, "timeout_deauth_block");
			} else {
				auth_change_state(cp1, FW_MARK_PREAUTHENTICATED, "timeout_deauth");
			}
		} else if (config->session_limit_block > 0
				&& cp1->counters.incoming / 1000 > config->session_limit_block * 1000) {
			/* Session ended (limit reached) */
			auth_change_state(cp1, FW_MARK_BLOCKED, "limitout_deauth_block");
		} else if (preauth_idle_timeout_secs > 0
				&& conn_state == FW_MARK_PREAUTHENTICATED
				&& (last_updated + preauth_idle_timeout_secs) <= now) {
			/* Timeout inactive preauthenticated user */
			debug(LOG_NOTICE, "Timeout preauthenticated idle user: %s %s, inactive: %ds, in: %llukB, out: %llukB",
				cp1->ip, cp1->mac, now - last_updated,
				cp1->counters.incoming / 1000, cp1->counters.outgoing / 1000);

			client_list_delete(cp1);
		} else if (auth_idle_timeout_secs > 0
				&& conn_state == FW_MARK_AUTHENTICATED
				&& (last_updated + auth_idle_timeout_secs) <= now) {
			/* Timeout inactive user */
			debug(LOG_NOTICE, "Timeout authenticated idle user: %s %s, inactive: %ds, in: %llukB, out: %llukB",
				cp1->ip, cp1->mac, now - last_updated,
				cp1->counters.incoming / 1000, cp1->counters.outgoing / 1000);

			auth_change_state(cp1, FW_MARK_PREAUTHENTICATED, "idle_deauth");
		}
	}
	UNLOCK_CLIENT_LIST();
}

/** Launched in its own thread.
 *  This just wakes up every config.checkinterval seconds, and calls fw_refresh_client_list()
@todo This thread loops infinitely, need a watchdog to verify that it is still running?
*/
void *
thread_client_timeout_check(void *arg)
{
	pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
	pthread_mutex_t cond_mutex = PTHREAD_MUTEX_INITIALIZER;
	struct timespec timeout;

	while (1) {
		debug(LOG_DEBUG, "Running fw_refresh_client_list()");

		fw_refresh_client_list();

		/* Sleep for config.checkinterval seconds... */
		timeout.tv_sec = time(NULL) + config_get_config()->checkinterval;
		timeout.tv_nsec = 0;

		/* Mutex must be locked for pthread_cond_timedwait... */
		pthread_mutex_lock(&cond_mutex);

		/* Thread safe "sleep" */
		pthread_cond_timedwait(&cond, &cond_mutex, &timeout);

		/* No longer needs to be locked */
		pthread_mutex_unlock(&cond_mutex);
	}

	return NULL;
}

/** Take action on a client.
 * Alter the firewall rules and client list accordingly.
*/
int
auth_client_deauth(const unsigned id, const char *reason)
{
	t_client *client;
	int rc = -1;

	LOCK_CLIENT_LIST();

	client = client_list_find_by_id(id);

	/* Client should already have hit the server and be on the client list */
	if (client == NULL) {
		debug(LOG_ERR, "Client %u to deauthenticate is not on client list", id);
		goto end;
	}

	rc = auth_change_state(client, FW_MARK_PREAUTHENTICATED, reason);

end:
	UNLOCK_CLIENT_LIST();
	return rc;
}

/**
 * @brief csv_escape_quoted RFC4180-style CSV field escaping.
 * Wraps src in double quotes and doubles any internal quote; CR/LF are replaced
 * with a space so a user-supplied newline can never inject a fabricated CSV row.
 * Always NUL-terminates and never overruns dst.
 */
static void csv_escape_quoted(char *dst, size_t dst_len, const char *src)
{
	size_t j = 0;
	if (dst_len == 0) return;
	if (src == NULL) src = "";
	dst[j++] = '"';
	for (size_t i = 0; src[i] != '\0' && j + 3 < dst_len; i++) {
		char c = src[i];
		if (c == '\n' || c == '\r') { dst[j++] = ' '; continue; }
		if (c == '"') { dst[j++] = '"'; dst[j++] = '"'; continue; }
		dst[j++] = c;
	}
	dst[j++] = '"';
	dst[j] = '\0';
}

/**
 * @brief json_escape_quoted writes src as a quoted JSON string into dst.
 * Escapes ", \\ and control characters (< 0x20). Always NUL-terminates and
 * never overruns dst. Used so user-supplied fields cannot break the spool JSONL.
 */
static void json_escape_quoted(char *dst, size_t dst_len, const char *src)
{
	size_t j = 0;
	if (dst_len == 0) return;
	if (src == NULL) src = "";
	dst[j++] = '"';
	for (size_t i = 0; src[i] != '\0' && j + 8 < dst_len; i++) {
		unsigned char c = (unsigned char)src[i];
		switch (c) {
		case '"':  dst[j++] = '\\'; dst[j++] = '"'; break;
		case '\\': dst[j++] = '\\'; dst[j++] = '\\'; break;
		case '\n': dst[j++] = '\\'; dst[j++] = 'n'; break;
		case '\r': dst[j++] = '\\'; dst[j++] = 'r'; break;
		case '\t': dst[j++] = '\\'; dst[j++] = 't'; break;
		default:
			if (c < 0x20) {
				j += snprintf(dst + j, dst_len - j, "\\u%04x", c);
			} else {
				dst[j++] = c;
			}
		}
	}
	dst[j++] = '"';
	dst[j] = '\0';
}

/**
 * @brief auth_client_auth_nolock authenticate a client without holding the CLIENT_LIST lock
 * @param id the client id
 * @param reason can be NULL
 * @param email the client's email
 * @param firstname the client's first name
 * @param sms_on "1"/non-empty when the guest opted in to SMS marketing, NULL/empty otherwise
 * @return 0 on success
 */
int
auth_client_auth_nolock(const unsigned id, const char *reason, const char *email, const char *phonenumber, const char *firstname, const char *sms_on)
{
	t_client *client;
	int rc;

	client = client_list_find_by_id(id);

	/* Client should already have hit the server and be on the client list */
	if (client == NULL) {
		debug(LOG_ERR, "Client %u to authenticate is not on client list", id);
		return -1;
	}

	rc = auth_change_state(client, FW_MARK_AUTHENTICATED, reason);
	if (rc == 0) {
		authenticated_since_start++;

		time_t rawtime;
		time(&rawtime);

		/* CSV-escape every user-controlled field so a comma cannot shift columns and a
		 * newline cannot inject a fabricated row (this data now feeds a marketing platform). */
		char e_email[512], e_phone[128], e_first[256];
		csv_escape_quoted(e_email, sizeof(e_email), email);
		csv_escape_quoted(e_phone, sizeof(e_phone), phonenumber);
		csv_escape_quoted(e_first, sizeof(e_first), firstname);

		char csv_entry[2048];
		snprintf(csv_entry, sizeof(csv_entry), "%ld, %s, %s, %s, %s, %s\n",
			rawtime, client->mac, client->ip, e_email, e_phone, e_first);

		/* registered_clients.csv is wiped every boot (start_router.py) and is kept only as
		 * the existing on-device success indicator. Both opens are NULL-checked so an
		 * unwritable file can never crash the daemon on a successful signup. */
		FILE *csv_file = fopen("/FlawkDetection/Flawk-5G/registered_clients.csv", "a");
		if (csv_file == NULL) {
			csv_file = fopen("/FlawkDetection/Flawk-5G/registered_clients.csv", "w");
		}
		if (csv_file != NULL) {
			fputs(csv_entry, csv_file);
			fclose(csv_file);
		} else {
			debug(LOG_ERR, "Could not open registered_clients.csv for writing");
		}

		/* Durable delivery spool for CMS/Patch forwarding. Unlike the CSV this path is NOT
		 * wiped on boot, so a guest who signs up just before a reboot is not lost. It is
		 * JSON-escaped, fsync'd and append-only; guest_forwarder.py delivers and dedupes. */
		char j_email[512], j_phone[128], j_first[256], j_mac[64], j_ip[64];
		json_escape_quoted(j_email, sizeof(j_email), email);
		json_escape_quoted(j_phone, sizeof(j_phone), phonenumber);
		json_escape_quoted(j_first, sizeof(j_first), firstname);
		json_escape_quoted(j_mac,   sizeof(j_mac),   client->mac);
		json_escape_quoted(j_ip,    sizeof(j_ip),    client->ip);
		const char *sms_val = (sms_on && sms_on[0] && strcmp(sms_on, "0") != 0) ? "1" : "0";

		FILE *spool = fopen("/FlawkDetection/Flawk-5G/guest_spool.jsonl", "a");
		if (spool != NULL) {
			fprintf(spool,
				"{\"ts\":%ld,\"mac\":%s,\"ip\":%s,\"email\":%s,\"phone\":%s,\"firstname\":%s,\"sms_on\":%s}\n",
				rawtime, j_mac, j_ip, j_email, j_phone, j_first, sms_val);
			fflush(spool);
			fsync(fileno(spool));
			fclose(spool);
		} else {
			debug(LOG_ERR, "Could not open guest_spool.jsonl for writing");
		}
	}

	return rc;
}

int
auth_client_auth(const unsigned id, const char *reason, const char *email, const char *phonenumber, const char *firstname, const char *sms_on)
{
	int rc;

	LOCK_CLIENT_LIST();
	rc = auth_client_auth_nolock(id, reason, email, phonenumber, firstname, sms_on);
	UNLOCK_CLIENT_LIST();

	return rc;
}

int
auth_client_trust(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!add_to_trusted_mac_list(mac) && !iptables_trust_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

	return rc;
}

int
auth_client_untrust(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!remove_from_trusted_mac_list(mac) && !iptables_untrust_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

/*
	if (rc == 0) {
		LOCK_CLIENT_LIST();
		t_client * client = client_list_find_by_mac(mac);
		if (client) {
			rc = auth_change_state(client, FW_MARK_PREAUTHENTICATED, "manual_untrust");
			if (rc == 0) {
				client->session_start = 0;
				client->session_end = 0;
			}
		}
		UNLOCK_CLIENT_LIST();
	}
*/

	return rc;
}

int
auth_client_allow(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!add_to_allowed_mac_list(mac) && !iptables_allow_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

	return rc;
}

int
auth_client_unallow(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!remove_from_allowed_mac_list(mac) && !iptables_unallow_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

	return rc;
}

int
auth_client_block(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!add_to_blocked_mac_list(mac) && !iptables_block_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

	return rc;
}

int
auth_client_unblock(const char *mac)
{
	int rc = -1;

	LOCK_CONFIG();

	if (!remove_from_blocked_mac_list(mac) && !iptables_unblock_mac(mac)) {
		rc = 0;
	}

	UNLOCK_CONFIG();

	return rc;
}

void
auth_client_deauth_all()
{
	t_client *cp1, *cp2;

	LOCK_CLIENT_LIST();

	for (cp1 = cp2 = client_get_first_client(); NULL != cp1; cp1 = cp2) {
		cp2 = cp1->next;

		if (!(cp1 = client_list_find_by_id(cp1->id))) {
			debug(LOG_ERR, "Client was freed while being re-validated!");
			continue;
		}

		auth_change_state(cp1, FW_MARK_PREAUTHENTICATED, "shutdown_deauth");
	}

	UNLOCK_CLIENT_LIST();
}
