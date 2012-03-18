SET @a = TO_DAYS(CURRENT_DATE());

DELETE FROM dspam_token_data 
  WHERE (innocent_hits*2) + spam_hits < 5
  AND @a-to_days(last_hit) > 60;
DELETE FROM dspam_token_data
  WHERE innocent_hits = 1 AND spam_hits = 0
  AND @a-to_days(last_hit) > 15;
DELETE FROM dspam_token_data
  WHERE innocent_hits = 0 AND spam_hits = 1
  AND @a-to_days(last_hit) > 15;

DELETE FROM dspam_token_data
  WHERE @a-to_days(last_hit) > 90;
DELETE FROM dspam_signature_data
  WHERE @a-1 > to_days(created_on);
