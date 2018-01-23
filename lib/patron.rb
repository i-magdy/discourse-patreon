require 'json'

module ::Patreon
  class Patron

    def self.update!
      Patreon::Campaign.update!
      sync_groups

      rewards = Patreon.get('rewards')
      ::MessageBus.publish '/patreon/background_sync', rewards
    end

    def self.sync_groups
      filters = Patreon.get('filters') || {}
      return if filters.blank?

      local_users = get_local_users

      filters.each_pair do |group_id, rewards|
        group = Group.find_by(id: group_id)

        next if group.nil?

        patron_ids = get_ids_by_rewards(rewards)

        next if patron_ids.blank?

        users = local_users.select do |user|
          id = user.custom_fields["patreon_id"]
          id.present? && patron_ids.include?(id)
        end

        group.transaction do
          (users - group.users).each do |user|
            group.add user
          end

          (group.users - users).each do |user|
            group.remove user
            user.custom_fields.except!(*Patreon::USER_DETAIL_FIELDS)
            user.save unless user.custom_fields_clean?
          end
        end
      end
    end

    def self.all
      Patreon.get('users') || {}
    end

    def self.update_local_user(user, patreon_id, skip_save = false)
      return if user.blank?

      user.custom_fields["patreon_id"] = patreon_id
      user.custom_fields["patreon_email"] = all[patreon_id]["email"]
      user.custom_fields["patreon_amount_cents"] = Patreon::Pledges.all[patreon_id]
      reward_users = Patreon::RewardUser.all
      user.custom_fields["patreon_rewards"] = Patreon::Reward.all.map { |i, r| r["title"] if reward_users[i].include?(patreon_id) }.compact.join(", ")
      user.save unless skip_save || user.custom_fields_clean?

      user
    end

    private

      def self.get_ids_by_rewards(rewards)
        reward_users = Patreon.get('reward-users')

        rewards.map { |id| reward_users[id] }.compact.flatten.uniq
      end

      def self.get_local_users
        users = User.joins(:_custom_fields).where(user_custom_fields: { name: 'patreon_id' }).uniq
        linked_patron_ids = UserCustomField.where(name: 'patreon_id').where("value IS NOT NULL").pluck(:value)

        oauth_users = Oauth2UserInfo.includes(:user).where(provider: "patreon")
        oauth_users = oauth_users.where("uid NOT IN (?)", linked_patron_ids) if linked_patron_ids.present?

        users += oauth_users.map do |o|
          linked_patron_ids << o.uid
          update_local_user(o.user, o.uid)
        end

        emails = all.reject { |p| linked_patron_ids.include?(p[0]) }.map { |p| { p[1]["email"] => p[0] } }.reduce({}, :merge)

        users += UserEmail.includes(:user).where(email: emails.keys).map do |ue|
          patreon_id = emails[ue.email]
          update_local_user(ue.user, patreon_id)
        end

        users.compact
      end
  end
end
