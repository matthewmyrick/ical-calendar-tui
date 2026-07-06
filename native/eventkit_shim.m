/*
 * eventkit_shim.m — EventKit access behind the C ABI in eventkit_shim.h.
 * All ObjC stays in this file; compiled with ARC (-fobjc-arc). Buffers
 * handed across the ABI are malloc'd copies freed by ek_free.
 */

#import <AppKit/AppKit.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

#include "eventkit_shim.h"

/* One store for the process lifetime (SPEC §5b): creating one per fetch is
 * slow and re-prompts on some macOS versions. Guarded by dispatch_once. */
static EKEventStore *shared_store(void) {
    static EKEventStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[EKEventStore alloc] init];
    });
    return store;
}

int ek_request_access(void) {
    if (@available(macOS 14.0, *)) {
        EKAuthorizationStatus status =
            [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
        if (status == EKAuthorizationStatusFullAccess) {
            return EK_OK;
        }
        if (status == EKAuthorizationStatusDenied ||
            status == EKAuthorizationStatusRestricted) {
            return EK_ERR_ACCESS_DENIED;
        }
        /* Not determined (or write-only): ask. Blocks on a semaphore — we
         * are on the poller thread, never the UI thread. */
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int result = EK_ERR_ACCESS_DENIED;
        [shared_store()
            requestFullAccessToEventsWithCompletion:^(BOOL granted,
                                                      NSError *_Nullable error) {
              (void)error;
              result = granted ? EK_OK : EK_ERR_ACCESS_DENIED;
              dispatch_semaphore_signal(done);
            }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        return result;
    }
    /* The spec targets macOS 14+; older systems use the ical_cli source. */
    return EK_ERR_ACCESS_DENIED;
}

/* EKParticipantStatus → the small int enum `ical -o json` uses
 * (0 unknown, 1 pending, 2 accepted, 3 declined, 4 tentative). */
static int participant_status_int(EKParticipantStatus status) {
    switch (status) {
    case EKParticipantStatusPending:
        return 1;
    case EKParticipantStatusAccepted:
        return 2;
    case EKParticipantStatusDeclined:
        return 3;
    case EKParticipantStatusTentative:
        return 4;
    default:
        return 0;
    }
}

static NSString *participant_status_string(EKParticipantStatus status) {
    switch (status) {
    case EKParticipantStatusPending:
        return @"pending";
    case EKParticipantStatusAccepted:
        return @"accepted";
    case EKParticipantStatusDeclined:
        return @"declined";
    case EKParticipantStatusTentative:
        return @"tentative";
    default:
        return @"unknown";
    }
}

/* mailto:dana@example.com → dana@example.com; other URLs pass through. */
static NSString *participant_email(EKParticipant *participant) {
    NSURL *url = participant.URL;
    if (url == nil) {
        return @"";
    }
    if ([url.scheme isEqualToString:@"mailto"] && url.resourceSpecifier != nil) {
        return url.resourceSpecifier;
    }
    return url.absoluteString ?: @"";
}

static NSString *rfc3339_utc(NSDate *date) {
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter stringFromDate:date] ?: @"";
}

/* NSColor (macOS EKCalendar.color) → "#RRGGBB"; empty when unavailable. */
static NSString *calendar_color_hex(EKCalendar *calendar) {
    NSColor *color = calendar.color;
    if (color == nil) {
        return @"";
    }
    NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (srgb == nil) {
        return @"";
    }
    int r = (int)lround(srgb.redComponent * 255.0);
    int g = (int)lround(srgb.greenComponent * 255.0);
    int b = (int)lround(srgb.blueComponent * 255.0);
    return [NSString stringWithFormat:@"#%02X%02X%02X", r, g, b];
}

int ek_fetch_events(double from_unix, double to_unix, char **json_utf8,
                    size_t *len) {
    if (json_utf8 == NULL || len == NULL) {
        return EK_ERR_INTERNAL;
    }
    @autoreleasepool {
        EKEventStore *store = shared_store();
        NSDate *from = [NSDate dateWithTimeIntervalSince1970:from_unix];
        NSDate *to = [NSDate dateWithTimeIntervalSince1970:to_unix];
        NSPredicate *predicate = [store predicateForEventsWithStartDate:from
                                                                endDate:to
                                                              calendars:nil];
        NSArray<EKEvent *> *events = [store eventsMatchingPredicate:predicate];

        NSMutableArray<NSDictionary *> *out =
            [NSMutableArray arrayWithCapacity:events.count];
        for (EKEvent *event in events) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"id"] = event.eventIdentifier ?: @"";
            entry[@"title"] = event.title ?: @"(untitled)";
            entry[@"start_date"] = rfc3339_utc(event.startDate);
            entry[@"end_date"] = rfc3339_utc(event.endDate);
            entry[@"all_day"] = @(event.allDay);
            entry[@"calendar"] = event.calendar.title ?: @"";
            entry[@"calendar_id"] = event.calendar.calendarIdentifier ?: @"";
            entry[@"calendar_color"] = calendar_color_hex(event.calendar);
            entry[@"location"] = event.location ?: @"";
            entry[@"notes"] = event.notes ?: @"";
            entry[@"url"] = event.URL.absoluteString ?: @"";
            entry[@"recurring"] = @(event.hasRecurrenceRules);

            EKParticipant *organizer = event.organizer;
            if (organizer != nil) {
                NSString *name = organizer.name ?: @"";
                entry[@"organizer"] =
                    name.length > 0 ? name : participant_email(organizer);
            }

            /* Your own RSVP, event-level (SPEC §6 self_rsvp). */
            NSString *self_status = @"";
            NSMutableArray<NSDictionary *> *attendees = [NSMutableArray array];
            for (EKParticipant *participant in event.attendees) {
                if (participant.isCurrentUser) {
                    self_status =
                        participant_status_string(participant.participantStatus);
                }
                [attendees addObject:@{
                    @"name" : participant.name ?: @"",
                    @"email" : participant_email(participant),
                    @"status" : @(participant_status_int(participant.participantStatus)),
                }];
            }
            if (self_status.length > 0) {
                entry[@"self_status"] = self_status;
            }
            if (attendees.count > 0) {
                entry[@"attendees"] = attendees;
            }
            [out addObject:entry];
        }

        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                       options:0
                                                         error:&error];
        if (data == nil || error != nil) {
            return EK_ERR_INTERNAL;
        }
        char *buffer = malloc(data.length);
        if (buffer == NULL) {
            return EK_ERR_OOM;
        }
        memcpy(buffer, data.bytes, data.length);
        *json_utf8 = buffer;
        *len = data.length;
        return EK_OK;
    }
}

void ek_free(char *ptr) { free(ptr); }
