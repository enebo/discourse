require 'rails_helper'
require_dependency 'jobs/base'

describe Jobs::UserEmail do

  before do
    SiteSetting.email_time_window_mins = 10
  end

  let(:user) { Fabricate(:user, last_seen_at: 11.minutes.ago) }
  let(:staged) { Fabricate(:user, staged: true, last_seen_at: 11.minutes.ago) }
  let(:suspended) { Fabricate(:user, last_seen_at: 10.minutes.ago, suspended_at: 5.minutes.ago, suspended_till: 7.days.from_now) }
  let(:anonymous) { Fabricate(:anonymous, last_seen_at: 11.minutes.ago) }

  it "raises an error when there is no user" do
    expect { Jobs::UserEmail.new.execute(type: :digest) }.to raise_error(Discourse::InvalidParameters)
  end

  it "raises an error when there is no type" do
    expect { Jobs::UserEmail.new.execute(user_id: user.id) }.to raise_error(Discourse::InvalidParameters)
  end

  it "raises an error when the type doesn't exist" do
    expect { Jobs::UserEmail.new.execute(type: :no_method, user_id: user.id) }.to raise_error(Discourse::InvalidParameters)
  end

  it "doesn't call the mailer when the user is missing" do
    Jobs::UserEmail.new.execute(type: :digest, user_id: 1234)

    expect(ActionMailer::Base.deliveries).to eq([])
  end

  it "doesn't call the mailer when the user is staged" do
    Jobs::UserEmail.new.execute(type: :digest, user_id: staged.id)

    expect(ActionMailer::Base.deliveries).to eq([])
  end

  context "bounce score" do

    it "always sends critical emails when bounce score threshold has been reached" do
      email_token = Fabricate(:email_token)
      user.user_stat.update(bounce_score: SiteSetting.bounce_score_threshold + 1)

      Jobs::CriticalUserEmail.new.execute(type: "signup", user_id: user.id, email_token: email_token.token)

      email_log = EmailLog.where(user_id: user.id).last
      expect(email_log.email_type).to eq("signup")

      expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
        user.email
      )
    end

  end

  context 'to_address' do
    it 'overwrites a to_address when present' do
      Jobs::UserEmail.new.execute(type: :confirm_new_email, user_id: user.id, to_address: 'jake@adventuretime.ooo')

      expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
        'jake@adventuretime.ooo'
      )
    end
  end

  context "disable_emails setting" do
    it "sends when no" do
      SiteSetting.disable_emails = 'no'
      Jobs::UserEmail.new.execute(type: :confirm_new_email, user_id: user.id)

      expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
        user.email
      )
    end

    it "does not send an email when yes" do
      SiteSetting.disable_emails = 'yes'
      Jobs::UserEmail.new.execute(type: :confirm_new_email, user_id: user.id)

      expect(ActionMailer::Base.deliveries).to eq([])
    end

    it "sends when critical" do
      SiteSetting.disable_emails = 'yes'
      Jobs::CriticalUserEmail.new.execute(type: :confirm_new_email, user_id: user.id)

      expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
        user.email
      )
    end
  end

  context "email_log" do
    let(:post) { Fabricate(:post) }

    before do
      SiteSetting.editing_grace_period = 0
      post
    end

    it "creates an email log when the mail is sent (via Email::Sender)" do
      last_emailed_at = user.last_emailed_at

      expect do
        Jobs::UserEmail.new.execute(type: :digest, user_id: user.id,)
      end.to change { EmailLog.count }.by(1)

      email_log = EmailLog.last

      expect(email_log.user).to eq(user)
      expect(email_log.post).to eq(nil)
      # last_emailed_at should have changed
      expect(email_log.user.last_emailed_at).to_not eq(last_emailed_at)
    end

    it "creates a skipped email log when the mail is skipped" do
      last_emailed_at = user.last_emailed_at
      user.update_columns(suspended_till: 1.year.from_now)

      expect do
        Jobs::UserEmail.new.execute(type: :digest, user_id: user.id)
      end.to change { SkippedEmailLog.count }.by(1)

      expect(SkippedEmailLog.exists?(
        email_type: "digest",
        user: user,
        post: nil,
        to_address: user.email,
        reason_type: SkippedEmailLog.reason_types[:user_email_user_suspended_not_pm]
      )).to eq(true)

      # last_emailed_at doesn't change
      expect(user.last_emailed_at).to eq(last_emailed_at)
    end

  end

  context 'args' do

    it 'passes a token as an argument when a token is present' do
      Jobs::UserEmail.new.execute(type: :forgot_password, user_id: user.id, email_token: 'asdfasdf')

      mail = ActionMailer::Base.deliveries.first

      expect(mail.to).to contain_exactly(user.email)
      expect(mail.body).to include("asdfasdf")
    end

    context "post" do
      let(:post) { Fabricate(:post, user: user) }

      it "doesn't send the email if you've seen the post" do
        PostTiming.record_timing(topic_id: post.topic_id, user_id: user.id, post_number: post.post_number, msecs: 6666)
        Jobs::UserEmail.new.execute(type: :user_private_message, user_id: user.id, post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      it "doesn't send the email if the user deleted the post" do
        post.update_column(:user_deleted, true)
        Jobs::UserEmail.new.execute(type: :user_private_message, user_id: user.id, post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      it "doesn't send the email if user of the post has been deleted" do
        post.update_attributes!(user_id: nil)
        Jobs::UserEmail.new.execute(type: :user_replied, user_id: user.id, post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      context 'user is suspended' do
        it "doesn't send email for a pm from a regular user" do
          Jobs::UserEmail.new.execute(type: :user_private_message, user_id: suspended.id, post_id: post.id)

          expect(ActionMailer::Base.deliveries).to eq([])
        end

        it "does send an email for a pm from a staff user" do
          pm_from_staff = Fabricate(:post, user: Fabricate(:moderator))
          pm_from_staff.topic.topic_allowed_users.create!(user_id: suspended.id)

          pm_notification = Fabricate(:notification,
            user: suspended,
            topic: pm_from_staff.topic,
            post_number: pm_from_staff.post_number,
            data: { original_post_id: pm_from_staff.id }.to_json
          )

          Jobs::UserEmail.new.execute(
            type: :user_private_message,
            user_id: suspended.id,
            post_id: pm_from_staff.id,
            notification_id: pm_notification.id
          )

          expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
            suspended.email
          )
        end
      end

      context 'user is anonymous' do
        before { SiteSetting.allow_anonymous_posting = true }

        it "doesn't send email for a pm from a regular user" do
          Jobs::UserEmail.new.execute(type: :user_private_message, user_id: anonymous.id, post_id: post.id)

          expect(ActionMailer::Base.deliveries).to eq([])
        end

        it "doesn't send email for a pm from a staff user" do
          pm_from_staff = Fabricate(:post, user: Fabricate(:moderator))
          pm_from_staff.topic.topic_allowed_users.create!(user_id: anonymous.id)
          Jobs::UserEmail.new.execute(type: :user_private_message, user_id: anonymous.id, post_id: pm_from_staff.id)

          expect(ActionMailer::Base.deliveries).to eq([])
        end
      end
    end

    context 'notification' do
      let(:post) { Fabricate(:post, user: user) }
      let!(:notification) {
        Fabricate(:notification,
                    user: user,
                    topic: post.topic,
                    post_number: post.post_number,
                    data: {
                      original_post_id: post.id
                    }.to_json
                 )
      }

      it "doesn't send the email if the notification has been seen" do
        notification.update_column(:read, true)
        message, err = Jobs::UserEmail.new.message_for_email(
          user,
          post,
          :user_mentioned,
          notification,
          notification_type: notification.notification_type,
          notification_data_hash: notification.data_hash
        )

        expect(message).to eq(nil)

        expect(SkippedEmailLog.exists?(
          email_type: "user_mentioned",
          user: user,
          post: post,
          to_address: user.email,
          reason_type: SkippedEmailLog.reason_types[:user_email_notification_already_read]
        )).to eq(true)
      end

      it "does send the email if the notification has been seen but the user is set for email_always" do
        notification.update_column(:read, true)
        user.user_option.update_column(:email_always, true)

        Jobs::UserEmail.new.execute(
          type: :user_mentioned,
          user_id: user.id,
          post_id: post.id,
          notification_id: notification.id
        )

        expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
          user.email
        )
      end

      it "does send the email if the user is using daily mailing list mode" do
        user.user_option.update(mailing_list_mode: true, mailing_list_mode_frequency: 0)

        Jobs::UserEmail.new.execute(
          type: :user_mentioned,
          user_id: user.id,
          post_id: post.id,
          notification_id: notification.id
        )

        expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
          user.email
        )
      end

      context "recently seen" do
        it "doesn't send an email to a user that's been recently seen" do
          user.update!(last_seen_at: 9.minutes.ago)

          Jobs::UserEmail.new.execute(
            type: :user_replied,
            user_id: user.id,
            post_id: post.id,
            notification_id: notification.id
          )

          expect(ActionMailer::Base.deliveries).to eq([])
        end

        it "does send an email to a user that's been recently seen but has email_always set" do
          user.update!(last_seen_at: 9.minutes.ago)
          user.user_option.update!(email_always: true)

          Jobs::UserEmail.new.execute(
            type: :user_replied,
            user_id: user.id,
            post_id: post.id,
            notification_id: notification.id
          )

          expect(ActionMailer::Base.deliveries.first.to).to contain_exactly(
            user.email
          )
        end
      end

      context 'max_emails_per_day_per_user limit is reached' do
        before do
          SiteSetting.max_emails_per_day_per_user = 2
          2.times { Fabricate(:email_log, user: user, email_type: 'blah', to_address: user.email) }
        end

        it "does not send notification if limit is reached" do
          expect do
            2.times do
              Jobs::UserEmail.new.execute(
                type: :user_mentioned,
                user_id: user.id,
                notification_id: notification.id,
                post_id: post.id
              )
            end
          end.to change { SkippedEmailLog.count }.by(1)

          expect(SkippedEmailLog.exists?(
            email_type: "user_mentioned",
            user: user,
            post: post,
            to_address: user.email,
            reason_type: SkippedEmailLog.reason_types[:exceeded_emails_limit]
          )).to eq(true)

          freeze_time(Time.zone.now.tomorrow + 1.second)

          expect do
            Jobs::UserEmail.new.execute(
              type: :user_mentioned,
              user_id: user.id,
              notification_id: notification.id,
              post_id: post.id
            )
          end.to change { SkippedEmailLog.count }.by(0)
        end

        it "sends critical email" do
          expect do
            Jobs::UserEmail.new.execute(
              type: :forgot_password,
              user_id: user.id,
              notification_id: notification.id,
            )
          end.to change { EmailLog.count }.by(1)

          expect(EmailLog.exists?(
            email_type: "forgot_password",
            user: user,
          )).to eq(true)
        end
      end

      it "erodes bounce score each time an email is sent" do
        SiteSetting.bounce_score_erode_on_send = 0.2

        user.user_stat.update(bounce_score: 2.7)

        Jobs::UserEmail.new.execute(
          type: :user_mentioned,
          user_id: user.id,
          notification_id: notification.id,
          post_id: post.id
        )

        user.user_stat.reload
        expect(user.user_stat.bounce_score).to eq(2.5)

        user.user_stat.update(bounce_score: 0)

        Jobs::UserEmail.new.execute(
          type: :user_mentioned,
          user_id: user.id,
          notification_id: notification.id,
          post_id: post.id
        )

        user.user_stat.reload
        expect(user.user_stat.bounce_score).to eq(0)
      end

      it "does not send notification if bounce threshold is reached" do
        user.user_stat.update(bounce_score: SiteSetting.bounce_score_threshold)

        expect do
          Jobs::UserEmail.new.execute(
            type: :user_mentioned,
            user_id: user.id,
            notification_id: notification.id,
            post_id: post.id
          )
        end.to change { SkippedEmailLog.count }.by(1)

        expect(SkippedEmailLog.exists?(
          email_type: "user_mentioned",
          user: user,
          post: post,
          to_address: user.email,
          reason_type: SkippedEmailLog.reason_types[:exceeded_bounces_limit]
        )).to eq(true)
      end

      it "doesn't send the mail if the user is using individual mailing list mode" do
        user.user_option.update(mailing_list_mode: true, mailing_list_mode_frequency: 1)
        # sometimes, we pass the notification_id
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_id: notification.id, post_id: post.id)
        # other times, we only pass the type of notification
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted", post_id: post.id)
        # When post is nil
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted")
        # When post does not have a topic
        post = Fabricate(:post)
        post.topic.destroy
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted", post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      it "doesn't send the mail if the user is using individual mailing list mode with no echo" do
        user.user_option.update(mailing_list_mode: true, mailing_list_mode_frequency: 2)
        # sometimes, we pass the notification_id
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_id: notification.id, post_id: post.id)
        # other times, we only pass the type of notification
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted", post_id: post.id)
        # When post is nil
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted")
        # When post does not have a topic
        post = Fabricate(:post)
        post.topic.destroy
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_type: "posted", post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      it "doesn't send the email if the post has been user deleted" do
        post.update_column(:user_deleted, true)
        Jobs::UserEmail.new.execute(type: :user_mentioned, user_id: user.id, notification_id: notification.id, post_id: post.id)

        expect(ActionMailer::Base.deliveries).to eq([])
      end

      context 'user is suspended' do
        it "doesn't send email for a pm from a regular user" do
          msg, err = Jobs::UserEmail.new.message_for_email(
              suspended,
              Fabricate.build(:post),
              :user_private_message,
              notification
          )

          expect(msg).to eq(nil)
          expect(err).not_to eq(nil)
        end

        context 'pm from staff' do
          before do
            @pm_from_staff = Fabricate(:post, user: Fabricate(:moderator))
            @pm_from_staff.topic.topic_allowed_users.create!(user_id: suspended.id)
            @pm_notification = Fabricate(:notification,
                                            user: suspended,
                                            topic: @pm_from_staff.topic,
                                            post_number: @pm_from_staff.post_number,
                                            data: { original_post_id: @pm_from_staff.id }.to_json
                                        )
          end

          let :sent_message do
            Jobs::UserEmail.new.message_for_email(
                suspended,
                @pm_from_staff,
                :user_private_message,
                @pm_notification
            )
          end

          it "sends an email" do
            msg, err = sent_message
            expect(msg).not_to be(nil)
            expect(err).to be(nil)
          end

          it "sends an email even if user was last seen recently" do
            suspended.update_column(:last_seen_at, 1.minute.ago)

            msg, err = sent_message
            expect(msg).not_to be(nil)
            expect(err).to be(nil)
          end
        end
      end

      context 'user is anonymous' do
        before { SiteSetting.allow_anonymous_posting = true }

        it "doesn't send email for a pm from a regular user" do
          Jobs::UserEmail.new.execute(
            type: :user_private_message,
            user_id: anonymous.id,
            post_id: post.id,
            notification_id: notification.id
          )

          expect(ActionMailer::Base.deliveries).to eq([])
        end

        it "doesn't send email for a pm from staff" do
          pm_from_staff = Fabricate(:post, user: Fabricate(:moderator))
          pm_from_staff.topic.topic_allowed_users.create!(user_id: anonymous.id)
          pm_notification = Fabricate(:notification,
                                          user: anonymous,
                                          topic: pm_from_staff.topic,
                                          post_number: pm_from_staff.post_number,
                                          data: { original_post_id: pm_from_staff.id }.to_json
                                      )
          Jobs::UserEmail.new.execute(
            type: :user_private_message,
            user_id: anonymous.id,
            post_id: pm_from_staff.id,
            notification_id: pm_notification.id
          )

          expect(ActionMailer::Base.deliveries).to eq([])
        end
      end
    end

  end

end
